require "rails_helper"

# Lane L7's rules on Conversation: who may read it (side_for, visible_to), read marks, the podcaster's answers and the
# Unverified brand label.
RSpec.describe Conversation do
  let(:owner) { create(:user) }
  let(:podcast) { claimed_podcast(owner: owner) }
  let(:asker) { create(:user) }
  let(:membership) { brand_member_for(asker) }
  let(:brand) { membership.brand }
  let(:conversation) { start_request(podcast, membership) }

  describe "#side_for and .visible_to" do
    it "puts the podcast's owner on the podcaster side and the asker on the brand side" do
      expect(conversation.side_for(owner)).to eq(:podcaster)
      expect(conversation.side_for(asker)).to eq(:brand)
      expect(described_class.visible_to(owner)).to contain_exactly(conversation)
      expect(described_class.visible_to(asker)).to contain_exactly(conversation)
    end

    it "keeps everyone else out, an unverified member of the same brand included" do
      stranger = create(:user)
      unverified_colleague = brand_member_for(brand: brand).user
      other_show_user = create(:show, podcast: podcast).user # a workspace for the podcast, not the owner

      [ stranger, unverified_colleague, other_show_user ].each do |user|
        expect(conversation.side_for(user)).to be_nil
        expect(described_class.visible_to(user)).to be_empty
      end
    end

    it "opens the brand's conversations to a verified member" do
      colleague = brand_member_for(brand: brand, verified: true).user

      expect(conversation.side_for(colleague)).to eq(:brand)
      expect(described_class.for_brand_user(colleague)).to contain_exactly(conversation)
    end

    it "has no podcaster side while the request waits for the claim" do
      waiting = start_request(create(:podcast), brand_member_for(asker))

      expect(waiting).to be_waiting_for_claim
      expect(described_class.for_podcaster(owner)).not_to include(waiting)
      expect(waiting.side_for(asker)).to eq(:brand)
    end
  end

  describe "read marks" do
    it "starts read for the brand and unread for the podcaster, and a message turns the other side unread" do
      expect(conversation.unread_for?(:brand)).to be(false)
      expect(conversation.unread_for?(:podcaster)).to be(true)

      conversation.mark_read!(:podcaster)
      expect(conversation.reload.unread_for?(:podcaster)).to be(false)

      travel 1.minute
      Conversations::Reply.call(conversation: conversation, user: owner, side: :podcaster, body: "Sounds good")
      conversation.reload
      expect(conversation.unread_for?(:brand)).to be(true)
      expect(conversation.unread_for?(:podcaster)).to be(false)
      expect(described_class.unread_by_brand).to include(conversation)
      expect(described_class.unread_by_podcaster).not_to include(conversation)
    end
  end

  describe "answers" do
    it "accepts an open request, records the first reply and leaves the brand unread" do
      conversation
      travel 2.hours
      conversation.accept!

      expect(conversation.reload).to be_accepted
      expect(conversation.first_reply_at).to be_within(1.second).of(Time.current)
      expect(conversation.unread_for?(:brand)).to be(true)
      expect(conversation.unread_for?(:podcaster)).to be(false)
    end

    it "declines with a reason and refuses a decline without one" do
      expect { conversation.decline!(reason: "  ") }.to raise_error(ActiveRecord::RecordInvalid)
      expect(conversation.reload).to be_open

      conversation.decline!(reason: "Booked through December.")
      expect(conversation.reload).to have_attributes(status: "declined", decline_reason: "Booked through December.")
    end

    it "refuses to answer twice or to answer a closed request" do
      conversation.accept!
      expect { conversation.decline!(reason: "No") }.to raise_error(Conversation::InvalidTransition, /already accepted/)

      conversation.close!(by: :brand)
      expect(conversation.reload).to have_attributes(status: "closed", closed_at: be_present)
      expect { conversation.close!(by: :podcaster) }.to raise_error(Conversation::InvalidTransition, /closed/)
    end

    it "keeps the first reply time when the podcaster answers again" do
      conversation.record_reply!(at: 1.hour.from_now)
      first = conversation.reload.first_reply_at
      conversation.accept!

      expect(conversation.reload.first_reply_at).to eq(first)
    end
  end

  it "labels a request unverified unless its asker verified a work email at the brand" do
    expect(conversation.from_verified_brand?).to be(false)

    membership.update!(verified_at: Time.current)
    expect(described_class.includes(started_by: :brand_members).find(conversation.id).from_verified_brand?).to be(true)
  end

  it "checks the format and the months" do
    conversation.format = "jingle"
    conversation.months = [ "2026-13" ]

    expect(conversation).not_to be_valid
    expect(conversation.errors.attribute_names).to include(:format, :months)
  end

  it "counts a report once" do
    expect(conversation.report!).to be(true)
    expect(conversation.report!).to be(false)
    expect(conversation.reload.reported_at).to be_present
  end
end
