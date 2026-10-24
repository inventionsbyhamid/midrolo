require "rails_helper"

RSpec.describe Podcasts::Directories::PodcastIndex do
  let(:key) { "test-key" }
  let(:secret) { "test-secret" }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:adapter) { described_class.new(key: key, secret: secret, cache: cache) }
  let(:base) { "https://api.podcastindex.org/api/1.0" }

  def fixture(name) = Rails.root.join("spec/fixtures/podcast_index/#{name}.json").read

  describe "#search" do
    it "signs the request and maps results to ShowInfo" do
      stub = stub_request(:get, "#{base}/search/byterm").with(query: { q: "widgets", max: 10 }) do |req|
        date = req.headers["X-Auth-Date"]
        req.headers["X-Auth-Key"] == key &&
          req.headers["User-Agent"] == "Midrolo/1.0" &&
          date.to_i.positive? &&
          req.headers["Authorization"] == Digest::SHA1.hexdigest(key + secret + date)
      end.to_return(status: 200, body: fixture("search_byterm"), headers: { "Content-Type" => "application/json" })

      shows = adapter.search("widgets")

      expect(stub).to have_been_requested
      expect(shows.size).to eq(2)
      first = shows.first
      expect(first).to be_a(Podcasts::ShowInfo)
      expect(first.directory_id).to eq("900001")
      expect(first.feed_url).to eq("https://widgethour.example.com/feed.xml")
      expect(first.categories).to eq(%w[Business Technology])
      expect(first.artwork_url).to eq("https://widgethour.example.com/art.png")
      expect(first.itunes_id).to eq("123456789")
      expect(first.episode_count).to eq(42)
      expect(shows.last.categories).to eq([])
      expect(shows.last.artwork_url).to eq("https://gadgetgossip.example.com/img.png")
    end

    it "caches responses for repeated terms" do
      stub = stub_request(:get, "#{base}/search/byterm").with(query: hash_including(q: "widgets"))
        .to_return(status: 200, body: fixture("search_byterm"))
      2.times { adapter.search("widgets") }
      expect(stub).to have_been_requested.once
    end

    it "returns [] for a blank term without calling the API" do
      expect(adapter.search("  ")).to eq([])
    end

    it "returns [] when the API errors" do
      stub_request(:get, "#{base}/search/byterm").with(query: hash_including({})).to_return(status: 500)
      expect(adapter.search("widgets")).to eq([])
    end
  end

  describe "#find" do
    it "looks up by feed id" do
      stub_request(:get, "#{base}/podcasts/byfeedid").with(query: { id: "900001" })
        .to_return(status: 200, body: fixture("podcasts_byfeedid"))
      show = adapter.find("900001")
      expect(show.title).to eq("The Widget Hour")
      expect(show.categories).to eq([ "Business" ])
    end

    it "returns nil when there is no feed" do
      stub_request(:get, "#{base}/podcasts/byfeedid").with(query: { id: "1" })
        .to_return(status: 200, body: '{"status":"true","feed":[]}')
      expect(adapter.find("1")).to be_nil
    end
  end

  describe "#find_by_feed_url" do
    it "looks up by feed url" do
      stub_request(:get, "#{base}/podcasts/byfeedurl").with(query: { url: "https://widgethour.example.com/feed.xml" })
        .to_return(status: 200, body: fixture("podcasts_byfeedid"))
      expect(adapter.find_by_feed_url("https://widgethour.example.com/feed.xml").directory_id).to eq("900001")
    end
  end

  describe "#find_by_itunes_id" do
    it "looks up by iTunes id" do
      stub_request(:get, "#{base}/podcasts/byitunesid").with(query: { id: "123456789" })
        .to_return(status: 200, body: fixture("podcasts_byfeedid"))
      expect(adapter.find_by_itunes_id("123456789").title).to eq("The Widget Hour")
    end
  end

  it "retries once on a 429 honoring Retry-After" do
    stub_request(:get, "#{base}/podcasts/byfeedid").with(query: { id: "900001" })
      .to_return({ status: 429, headers: { "Retry-After" => "0" } }, { status: 200, body: fixture("podcasts_byfeedid") })
    expect(adapter.find("900001").title).to eq("The Widget Hour")
  end
end
