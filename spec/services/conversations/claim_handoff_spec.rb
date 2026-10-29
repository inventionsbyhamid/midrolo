require "rails_helper"

# A claim opens the requests that waited for it and tells the new owner once (Show#verify! calls it).
RSpec.describe Conversations::ClaimHandoff do
  include ActiveJob::TestHelper

  before { ActionMailer::Base.deliveries.clear }

  let(:podcast) { create(:podcast, title: "Night Owls", owner_email: "feed-owner@example.com") }
  let(:claimant) { create(:user, email: "host@example.com") }

  before do
    2.times { start_request(podcast, brand_member_for) }
  end

  it "opens the waiting requests on a claim and emails the account that claimed, not the feed's owner" do
    show = create(:show, user: claimant, podcast: podcast)

    perform_enqueued_jobs { show.verify!(via: "email") }

    expect(podcast.conversations.pluck(:status)).to eq(%w[open open])
    expect(Conversation.for_podcaster(claimant).count).to eq(2)
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([ [ "host@example.com" ] ])
    expect(ActionMailer::Base.deliveries.last.subject).to eq("2 brands asked about sponsoring Night Owls")
  end

  it "does nothing the second time" do
    create(:show, user: claimant, podcast: podcast).verify!(via: "email")

    expect(described_class.call(podcast)).to eq(0)
  end

  it "keeps a brand the podcast blocked closed" do
    blocked = podcast.conversations.first
    create(:block, podcast: podcast, brand: blocked.brand)

    create(:show, user: claimant, podcast: podcast).verify!(via: "email")

    expect(blocked.reload).to be_closed
    expect(podcast.conversations.open.count).to eq(1)
  end
end
