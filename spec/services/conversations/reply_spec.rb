require "rails_helper"

# A message from either side: the podcaster's first is the first reply, and the other side is emailed once per unread
# stretch, never while the request waits for the claim.
RSpec.describe Conversations::Reply do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, email: "maya@example.com") }
  let(:podcast) { claimed_podcast(owner: owner) }
  let(:asker) { create(:user, email: "sam@fieldnote.example") }
  let(:membership) { brand_member_for(asker) }
  let(:conversation) { start_request(podcast, membership) }

  def reply(user, side, body = "Thanks!", target = conversation)
    perform_enqueued_jobs { described_class.call(conversation: target, user: user, side: side, body: body) }
  end

  before do
    conversation
    ActionMailer::Base.deliveries.clear
  end

  it "records the podcaster's first reply and emails the asker, once per unread stretch" do
    travel 3.hours
    result = reply(owner, :podcaster, "Happy to. What's the product?")

    expect(result).to be_ok
    expect(conversation.reload.first_reply_at).to be_within(1.second).of(Time.current)
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([ [ "sam@fieldnote.example" ] ])

    reply(owner, :podcaster, "Also, which months?")
    expect(ActionMailer::Base.deliveries.size).to eq(1) # the asker hasn't read the first yet

    conversation.reload.mark_read!(:brand)
    travel 1.minute
    reply(owner, :podcaster, "Following up")
    expect(ActionMailer::Base.deliveries.size).to eq(2)
  end

  it "doesn't email the owner about a brand's follow up while the request is still unread" do
    reply(asker, :brand, "One more thing")

    expect(ActionMailer::Base.deliveries).to be_empty
    expect(conversation.reload.first_reply_at).to be_nil
    expect(conversation.messages.count).to eq(2)
  end

  it "takes the brand's notes on a waiting request and emails nobody" do
    waiting = start_request(create(:podcast, owner_email: "feed-owner@example.com"), brand_member_for(asker))

    expect(reply(asker, :brand, "Adding our launch date", waiting)).to be_ok
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "refuses a closed conversation and an empty message" do
    expect(reply(asker, :brand, "  ").error).to eq(described_class::EMPTY)
    expect(reply(asker, :brand, "x" * 4001).error).to eq("Keep it under 4,000 characters.")

    conversation.close!(by: :brand)
    result = reply(owner, :podcaster)
    expect(result.error).to eq(described_class::CLOSED)
    expect(conversation.messages.count).to eq(1)
  end
end
