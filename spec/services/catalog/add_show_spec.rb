require "rails_helper"

RSpec.describe Catalog::AddShow do
  include ActiveJob::TestHelper

  before do
    Podcasts::Directory.reset!
    allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ])
  end

  it "adds a show by name, the hit whose title matches, as an admin addition queued at high priority" do
    result = described_class.call("Cold Case Cafe")

    expect(result).to be_ok
    expect(result.created).to be(true)
    expect([ result.podcast.title, result.podcast.source, result.podcast.feed_url ]).to eq([ "Cold Case Cafe", "admin", "fake://fake-8" ])
    expect(Catalog::IngestPodcastJob).to have_been_enqueued.with(result.podcast.id).at_priority(0)
  end

  it "finds the same show again instead of adding it twice" do
    first = described_class.call("Cold Case Cafe").podcast
    again = described_class.call("cold case cafe")
    expect([ again.podcast, again.created ]).to eq([ first, false ])
  end

  it "adds a show by its RSS feed URL, read from the feed itself" do
    url = "https://feeds.example.com/tidepool.xml"
    stub_request(:get, url).to_return(status: 200, body: Rails.root.join("spec/fixtures/feeds/catalog_namespace.xml").binread)

    result = described_class.call(url)
    expect([ result.podcast.title, result.podcast.feed_url ]).to eq([ "The Tidepool Hour", url ])
  end

  it "adds a show by its Apple Podcasts link" do
    result = described_class.call("https://podcasts.apple.com/us/podcast/x/id#{Podcasts::Directories::Fake.itunes_id_for('fake-5')}")
    expect(result.podcast.title).to eq("Bootstrapped Brains")
  end

  it "explains what it can't do" do
    expect(described_class.call(" ").error).to eq(described_class::BLANK)
    expect(described_class.call("https://open.spotify.com/show/abc").error).to eq(described_class::SPOTIFY_ERROR)
    expect(described_class.call("No Such Show Anywhere").error).to eq(described_class::NOT_FOUND)

    allow(Podcasts::Directory).to receive(:current).and_raise(Podcasts::Directory::Unavailable)
    expect(described_class.call("Cold Case Cafe").error).to eq(described_class::UNAVAILABLE)
  end
end
