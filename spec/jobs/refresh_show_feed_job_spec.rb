require "rails_helper"

RSpec.describe RefreshShowFeedJob do
  it "stores owner email, cadence and episode count from the feed" do
    show = create(:show, directory_id: "fake-1", feed_url: "fake://fake-1")
    described_class.perform_now(show.id)

    show.reload
    expect(show.owner_email).to eq("host@the-founder-s-ledger.example")
    expect(show.cadence_days).to eq(7)
    expect(show.episode_count).to be_positive
  end

  it "does not raise or overwrite anything when the feed has warnings" do
    show = create(:show, feed_url: "fake://nope", owner_email: "keep@example.com", cadence_days: 3, episode_count: 40)
    expect { described_class.perform_now(show.id) }.not_to raise_error

    show.reload
    expect([ show.owner_email, show.cadence_days, show.episode_count ]).to eq([ "keep@example.com", 3, 40 ])
  end

  it "keeps a larger directory episode count" do
    show = create(:show, feed_url: "fake://fake-1", episode_count: 400)
    described_class.perform_now(show.id)
    expect(show.reload.episode_count).to eq(400)
  end

  it "ignores a deleted show" do
    expect { described_class.perform_now(0) }.not_to raise_error
  end
end
