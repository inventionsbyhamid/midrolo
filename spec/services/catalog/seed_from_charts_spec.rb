require "rails_helper"

# Apple's chart and lookup are hand-written fixtures (spec/fixtures/apple, made-up shows). The chart has three shows: one
# the catalog holds already, one the demo directory knows by its Apple id (Bootstrapped Brains, fake-5), and one only
# Apple's lookup knows (The Tidepool Hour, whose feed is spec/fixtures/feeds/catalog_namespace.xml).
RSpec.describe Catalog::SeedFromCharts do
  include ActiveJob::TestHelper

  let(:chart_url) { "https://itunes.apple.com/us/rss/toppodcasts/limit=200/json" }
  let(:lookup_url) { "https://itunes.apple.com/lookup?id=1500000003&entity=podcast" }
  let(:feed_url) { "https://feeds.example.com/tidepool.xml" }
  let(:sleeps) { [] }
  let(:lines) { [] }

  before do
    Podcasts::Directory.reset!
    allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ])
    stub_request(:get, chart_url).to_return(status: 200, body: fixture("top_podcasts.json"))
    stub_request(:get, lookup_url).to_return(status: 200, body: fixture("lookup_tidepool.json"))
    stub_request(:get, feed_url).to_return(status: 200, body: Rails.root.join("spec/fixtures/feeds/catalog_namespace.xml").binread)
    create(:podcast, title: "Already Here Weekly", apple_id: 1_500_000_001)
  end

  def fixture(name) = Rails.root.join("spec/fixtures/apple", name).read

  def seed(**options)
    described_class.call(sleeper: ->(seconds) { sleeps << seconds }, clock: -> { 100.0 }, log: ->(line) { lines << line },
                         **options)
  end

  it "adds the charted shows the catalog lacks, by Apple id in the directory, else by Apple's lookup and the feed" do
    result = seed

    expect(result).to have_attributes(charted: 3, added: 2, existing: 1, skipped: 0, failed: 0)
    brains = Podcast.find_by!(apple_id: 1_000_000_005)
    tidepool = Podcast.find_by!(apple_id: 1_500_000_003)
    expect([ brains.title, brains.feed_url, brains.source ]).to eq([ "Bootstrapped Brains", "fake://fake-5", "admin" ])
    expect([ tidepool.title, tidepool.feed_url, tidepool.source, tidepool.status ])
      .to eq([ "The Tidepool Hour", feed_url, "admin", "pending" ])
    expect(Catalog::IngestPodcastJob).to have_been_enqueued.with(brains.id).at_priority(20)
    expect(Catalog::IngestPodcastJob).to have_been_enqueued.with(tidepool.id).at_priority(20)
    expect(a_request(:get, lookup_url)).to have_been_made.once
  end

  it "paces directory and Apple lookups to about one a second" do
    seed
    # Bootstrapped Brains' directory lookup goes first; then The Tidepool Hour's directory lookup, Apple's lookup, and
    # the directory lookup of the feed URL Apple gave.
    expect(sleeps).to eq([ 1.0, 1.0, 1.0 ])
  end

  it "is idempotent: a rerun adds nothing and looks nothing up" do
    seed
    directory = Podcasts::Directory.current
    allow(directory).to receive(:find_by_itunes_id).and_call_original

    expect(seed).to have_attributes(charted: 3, added: 0, existing: 3, failed: 0)
    expect(directory).not_to have_received(:find_by_itunes_id)
    expect(a_request(:get, lookup_url)).to have_been_made.once
    expect(Podcast.count).to eq(3)
  end

  it "counts a show the catalog holds under its feed as existing, and stores its Apple id for the next run" do
    held = create(:podcast, title: "Bootstrapped Brains", feed_url: "fake://fake-5", source: "qloo_seed")

    expect(seed).to have_attributes(added: 1, existing: 2)
    expect([ held.reload.apple_id, held.source ]).to eq([ 1_000_000_005, "qloo_seed" ])
    expect(Catalog::IngestPodcastJob).not_to have_been_enqueued.with(held.id)
  end

  it "skips removed podcasts and suppressed feeds, never bringing them back" do
    Podcast.find_by!(apple_id: 1_500_000_001).update!(status: "removed")
    Suppression.create!(kind: "podcast", value: Suppression.feed_digest(feed_url))

    expect(seed).to have_attributes(added: 1, existing: 0, skipped: 2, failed: 0)
    expect(Podcast.exists?(feed_url: feed_url)).to be(false)
    expect(lines).to include("skipped: The Tidepool Hour (Apple id 1500000003): its feed is suppressed")
  end

  it "counts a show without a feed it can find or read as failed, says why, and carries on" do
    stub_request(:get, lookup_url).to_return(status: 200, body: { resultCount: 0, results: [] }.to_json)
    expect(seed).to have_attributes(added: 1, existing: 1, failed: 1)
    expect(lines).to include("failed: The Tidepool Hour (Apple id 1500000003): Apple lists no feed for it")

    stub_request(:get, lookup_url).to_return(status: 500)
    expect(seed).to have_attributes(added: 0, failed: 1)
    expect(lines.last).to match(/failed: The Tidepool Hour .*HTTP 500/)

    stub_request(:get, lookup_url).to_return(status: 200, body: fixture("lookup_tidepool.json"))
    stub_request(:get, feed_url).to_return(status: 404)
    expect(seed).to have_attributes(added: 0, failed: 1)
    expect(lines.last).to eq("failed: The Tidepool Hour (Apple id 1500000003): its feed can't be read (#{feed_url})")
  end

  it "reads the feed itself when Podcast Index refuses the Apple id and the feed URL" do
    base = "https://api.podcastindex.org/api/1.0"
    allow(Podcasts::Directory).to receive(:current)
      .and_return(Podcasts::Directories::PodcastIndex.new(key: "key", secret: "secret", cache: ActiveSupport::Cache::NullStore.new))
    stub_request(:get, "#{base}/podcasts/byitunesid").with(query: { id: "1000000005" }).to_return(
      status: 200, body: { status: "true", feed: { id: 920_666, title: "Bootstrapped Brains", author: "Lena Fischer",
                                                    url: "https://feeds.example.com/brains.xml", itunesId: 1_000_000_005,
                                                    language: "en" } }.to_json
    )
    stub_request(:get, "#{base}/podcasts/byitunesid").with(query: { id: "1500000003" }).to_return(status: 400, body: "{}")
    stub_request(:get, "#{base}/podcasts/byfeedurl").with(query: { url: feed_url }).to_return(status: 400, body: "{}")

    expect(seed).to have_attributes(added: 2, existing: 1, failed: 0)
    expect(Podcast.find_by!(apple_id: 1_000_000_005)).to have_attributes(podcast_index_id: 920_666, feed_url: "https://feeds.example.com/brains.xml")
    expect(Podcast.find_by!(apple_id: 1_500_000_003)).to have_attributes(title: "The Tidepool Hour", feed_url: feed_url)
  end

  it "reads one genre's chart, and a chart of one show" do
    one = JSON.parse(fixture("top_podcasts.json"))
    one["feed"]["entry"] = one["feed"]["entry"][1]
    stub_request(:get, "https://itunes.apple.com/gb/rss/toppodcasts/limit=1/genre=1321/json").to_return(status: 200, body: one.to_json)

    expect(seed(country: "GB", limit: 1, genre: "1321")).to have_attributes(charted: 1, added: 1)
    expect(Podcast.find_by(apple_id: 1_000_000_005)).to be_present
  end

  it "refuses a bad country, limit or genre before asking Apple" do
    expect { seed(country: "usa") }.to raise_error(ArgumentError, /two letter/)
    expect { seed(limit: 201) }.to raise_error(ArgumentError, /1 to 200/)
    expect { seed(limit: nil) }.to raise_error(ArgumentError, /1 to 200/)
    expect { seed(genre: "tech") }.to raise_error(ArgumentError, /genre id/)
    expect(a_request(:get, /itunes\.apple\.com/)).not_to have_been_made
  end

  it "raises when the chart can't be read, having added nothing" do
    stub_request(:get, chart_url).to_return(status: 504)
    expect { seed }.to raise_error(Catalog::AppleChart::Unavailable, /HTTP 504/)
    expect(Podcast.count).to eq(1)
  end
end
