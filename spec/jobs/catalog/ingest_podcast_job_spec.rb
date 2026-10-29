require "rails_helper"

# For now what RefreshShowFeedJob did for a show, done for the podcast (lane L1 makes it the full ingest).
RSpec.describe Catalog::IngestPodcastJob do
  it "runs on the catalog queue, one at a time per podcast" do
    expect(described_class.new.queue_name).to eq("catalog")
    expect(described_class.new(1).concurrency_key).to include("1")
  end

  it "stores owner email (encrypted), cadence and episode count from the feed" do
    podcast = create(:podcast, feed_url: "fake://fake-1")
    described_class.perform_now(podcast.id)

    podcast.reload
    expect(podcast.owner_email).to eq("host@the-founder-s-ledger.example")
    expect(podcast.cadence_days).to eq(7)
    expect(podcast.episode_count).to be_positive
    expect(podcast.feed_checked_at).to be_present
    stored = Podcast.connection.select_value("SELECT owner_email FROM podcasts WHERE id = #{podcast.id}")
    expect(stored).not_to include("host@")
  end

  it "stores the podcast's website from the feed's channel link, when it is http(s)" do
    podcast = create(:podcast, feed_url: "https://indie.example.com/feed.xml")
    feed = Podcasts::Feed.new(title: "Indie", description: nil, owner_email: nil, owner_name: nil, episodes: [],
                              cadence_days: nil, warnings: [], website: "https://indie.example.com/")
    allow(Podcasts::FeedReader).to receive(:new).and_return(instance_double(Podcasts::FeedReader, read: feed))

    described_class.perform_now(podcast.id)
    expect(podcast.reload.website).to eq("https://indie.example.com/")

    allow(Podcasts::FeedReader).to receive(:new).and_return(instance_double(Podcasts::FeedReader, read: feed.with(website: "javascript:alert(1)")))
    described_class.perform_now(podcast.id)
    expect(podcast.reload.website).to eq("https://indie.example.com/")
  end

  it "does not raise or overwrite anything when the feed has warnings" do
    podcast = create(:podcast, feed_url: "fake://nope", owner_email: "keep@example.com", cadence_days: 3, episode_count: 40)
    expect { described_class.perform_now(podcast.id) }.not_to raise_error

    podcast.reload
    expect([ podcast.owner_email, podcast.cadence_days, podcast.episode_count ]).to eq([ "keep@example.com", 3, 40 ])
  end

  it "keeps a larger directory episode count" do
    podcast = create(:podcast, feed_url: "fake://fake-1", episode_count: 400)
    described_class.perform_now(podcast.id)
    expect(podcast.reload.episode_count).to eq(400)
  end

  it "ignores a deleted or removed podcast" do
    expect { described_class.perform_now(0) }.not_to raise_error

    removed = create(:podcast, feed_url: "fake://fake-1", status: "removed")
    described_class.perform_now(removed.id)
    expect(removed.reload.feed_checked_at).to be_nil
  end
end
