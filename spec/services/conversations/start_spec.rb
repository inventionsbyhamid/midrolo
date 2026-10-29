require "rails_helper"

# Request a spot (build spec L7): open and emailed to the owner of a claimed show; held, never emailed, for an
# unclaimed one; and the spam guards (own show, blocks, one ongoing request, the daily allowance).
RSpec.describe Conversations::Start do
  include ActiveJob::TestHelper

  before { ActionMailer::Base.deliveries.clear }

  let(:owner) { create(:user, email: "maya@example.com") }
  let(:podcast) { claimed_podcast(owner: owner) }
  let(:membership) { brand_member_for(create(:user, email: "sam@fieldnote.example")) }

  def call(target = podcast, member = membership, **attributes)
    described_class.call(podcast: target, membership: member, form: request_form(**attributes))
  end

  it "opens a request on a claimed show with its first message, and emails the owner's account" do
    result = perform_enqueued_jobs { call(budget: "1,200", format: "preroll") }

    conversation = result.conversation
    expect(result).to be_ok
    expect(conversation).to have_attributes(status: "open", format: "preroll", budget_cents: 120_000,
                                            started_by: membership.user, brand: membership.brand)
    expect(conversation.messages.map(&:body)).to eq([ "We'd love a midroll next month." ])
    expect(conversation.last_message_at).to be_present
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([ [ "maya@example.com" ] ])
  end

  it "holds a request on an unclaimed show and never emails its feed's owner" do
    unclaimed = create(:podcast, owner_email: "feed-owner@example.com")

    result = perform_enqueued_jobs { call(unclaimed) }

    expect(result.conversation).to be_waiting_for_claim
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "touches the podcast so its page's cache changes" do
    podcast
    travel 1.minute
    expect { call }.to(change { podcast.reload.updated_at })
  end

  it "returns the ongoing request instead of a second one" do
    first = call.conversation
    again = call

    expect(again).to have_attributes(ok?: true, existing: true, conversation: first)
    expect(Conversation.count).to eq(1)
  end

  it "refuses the show's own owner, a blocked brand and a removed show" do
    own = brand_member_for(owner)
    expect(call(podcast, own).error).to eq(described_class::OWN_SHOW)

    create(:block, podcast: podcast, brand: membership.brand)
    expect(call.error).to eq(described_class::BLOCKED)

    expect(call(create(:podcast, status: "removed")).error).to eq(described_class::UNAVAILABLE)
    expect(Conversation.count).to eq(0)
  end

  it "passes the form's errors back" do
    result = call(body: " ", budget: "lots")

    expect(result).not_to be_ok
    expect(result.error).to eq("Message can't be blank")
    expect(Conversation.count).to eq(0)
  end

  describe "the daily allowance per brand member" do
    it "lets an unverified member send 3 requests in 24 hours" do
      3.times { expect(call(create(:podcast))).to be_ok }

      refused = call(create(:podcast))
      expect(refused.error).to include("3 requests in the last 24 hours", "Verify your work email to send up to 25")
      expect(Conversation.count).to eq(3)

      travel 25.hours
      expect(call(create(:podcast))).to be_ok
    end

    it "lets a verified member send 25" do
      membership.update!(verified_at: Time.current)
      25.times { call(create(:podcast)) }

      expect(Conversation.count).to eq(25)
      expect(call(create(:podcast)).error).to include("25 requests", "Try again tomorrow")
      expect(described_class.remaining_today(membership)).to eq(0)
    end

    it "counts a request a later block closed" do
      2.times { call(create(:podcast)) }
      Conversation.update_all(status: "closed")

      expect(described_class.remaining_today(membership)).to eq(1)
    end
  end
end
