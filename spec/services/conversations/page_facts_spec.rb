require "rails_helper"

# The podcast page's Request a spot box: the waiting count, the reply time line and where the viewer stands.
RSpec.describe Conversations::PageFacts do
  let(:owner) { create(:user) }
  let(:podcast) { claimed_podcast(owner: owner) }

  # A replied request: asked at asked_at, first reply after reply_after.
  def replied(asked_at:, reply_after:)
    create(:conversation, podcast: podcast, created_at: asked_at, first_reply_at: asked_at + reply_after)
  end

  describe "#waiting_count" do
    it "counts the brands waiting on an unclaimed show, and nothing once it's claimed" do
      unclaimed = create(:podcast)
      3.times { create(:conversation, podcast: unclaimed, status: "waiting_for_claim") }
      create(:conversation, podcast: unclaimed, status: "closed")

      expect(described_class.new(unclaimed).waiting_count).to eq(3)
      expect(described_class.new(podcast).waiting_count).to eq(0)
    end
  end

  describe "#reply_time" do
    it "says nothing under 3 replies" do
      2.times { replied(asked_at: 1.day.from_now, reply_after: 2.hours) }

      expect(described_class.new(podcast).reply_time).to be_nil
    end

    it "gives the median from the request, or from the claim for one that waited" do
      later = 1.hour.from_now
      replied(asked_at: later, reply_after: 2.hours)
      replied(asked_at: later, reply_after: 5.hours)
      replied(asked_at: later, reply_after: 30.hours)

      expect(described_class.new(podcast).reply_time).to eq("Usually replies within a day")

      # Asked long before the claim: counted from the claim, so it doesn't look slow.
      replied(asked_at: podcast.claimed_at - 30.days, reply_after: 30.days + 1.hour)
      expect(described_class.new(podcast).reply_time).to eq("Usually replies within a day")
    end

    it "steps to a few days and a week, then says nothing" do
      later = 1.hour.from_now
      3.times { replied(asked_at: later, reply_after: 2.days) }
      expect(described_class.new(podcast).reply_time).to eq("Usually replies within a few days")

      Conversation.update_all("first_reply_at = created_at + interval '5 days'")
      expect(described_class.new(podcast).reply_time).to eq("Usually replies within a week")

      Conversation.update_all("first_reply_at = created_at + interval '9 days'")
      expect(described_class.new(podcast).reply_time).to be_nil
    end
  end

  describe "#viewer" do
    it "knows the signed-out visitor, the owner and someone without a brand" do
      expect(described_class.new(podcast).viewer.state).to eq(:signed_out)
      expect(described_class.new(podcast, user: owner).viewer.state).to eq(:owner)
      expect(described_class.new(podcast, user: create(:user)).viewer.state).to eq(:no_brand)
    end

    it "finds the member's ongoing request, their blocked brands and the brands they may ask as" do
      membership = brand_member_for
      user = membership.user
      expect(described_class.new(podcast, user: user).viewer).to have_attributes(state: :ready, membership: membership)

      conversation = start_request(podcast, membership)
      expect(described_class.new(podcast, user: user).viewer).to have_attributes(state: :ongoing, conversation: conversation)

      Conversations::BlockBrand.block(podcast: podcast, brand: membership.brand)
      expect(described_class.new(podcast, user: user).viewer.state).to eq(:blocked)
    end
  end
end
