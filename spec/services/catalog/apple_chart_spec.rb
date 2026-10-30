require "rails_helper"

# Hand-written fixtures in Apple's legacy chart and lookup formats (spec/fixtures/apple); no real data.
RSpec.describe Catalog::AppleChart do
  let(:chart_url) { "https://itunes.apple.com/us/rss/toppodcasts/limit=200/json" }
  let(:chart) { JSON.parse(Rails.root.join("spec/fixtures/apple/top_podcasts.json").read) }
  let(:lookup_url) { "https://itunes.apple.com/lookup?id=1500000003&entity=podcast" }
  let(:lookup) { JSON.parse(Rails.root.join("spec/fixtures/apple/lookup_tidepool.json").read) }

  before { allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ]) }

  describe ".top" do
    it "reads the chart's Apple ids, names and artists in rank order" do
      stub_request(:get, chart_url).to_return(status: 200, body: chart.to_json)

      expect(described_class.top).to eq([
        described_class::Entry.new(apple_id: "1500000001", name: "Already Here Weekly", artist: "Pat Example"),
        described_class::Entry.new(apple_id: "1000000005", name: "Bootstrapped Brains", artist: "Lena Fischer"),
        described_class::Entry.new(apple_id: "1500000003", name: "The Tidepool Hour", artist: "Marina Reyes")
      ])
    end

    it "drops entries without an Apple id or a name, and repeats" do
      entries = chart["feed"]["entry"]
      entries[0]["id"]["attributes"]["im:id"] = "not-an-id"
      entries[1]["im:name"]["label"] = " "
      chart["feed"]["entry"] = entries + [ entries[2], "junk" ]
      stub_request(:get, chart_url).to_return(status: 200, body: chart.to_json)

      expect(described_class.top.map(&:apple_id)).to eq([ "1500000003" ])
    end

    it "reads an empty chart as no shows" do
      stub_request(:get, chart_url).to_return(status: 200, body: { feed: { title: { label: "Top Podcasts" } } }.to_json)
      expect(described_class.top).to eq([])
    end

    it "follows a redirect, vetting each hop" do
      moved = "https://itunes.apple.com/us/rss/toppodcasts/limit=200/explicit=true/json"
      stub_request(:get, chart_url).to_return(status: 301, headers: { "Location" => moved })
      stub_request(:get, moved).to_return(status: 200, body: chart.to_json)
      expect(described_class.top.size).to eq(3)

      stub_request(:get, chart_url).to_return(status: 302, headers: { "Location" => "http://127.0.0.1/admin" })
      expect { described_class.top }.to raise_error(described_class::Unavailable, /internal address/)
    end

    it "refuses an answer over the byte cap, and one that isn't JSON" do
      stub_const("#{described_class}::MAX_BYTES", 100)
      stub_request(:get, chart_url).to_return(status: 200, body: chart.to_json)
      expect { described_class.top }.to raise_error(described_class::Unavailable, /over 100 bytes/)

      stub_request(:get, chart_url).to_return(status: 200, body: "<html>busy</html>")
      expect { described_class.top }.to raise_error(described_class::Unavailable, /isn't JSON/)
    end
  end

  describe ".feed_url" do
    it "gives the feed URL Apple lists for the show" do
      stub_request(:get, lookup_url).to_return(status: 200, body: lookup.to_json)
      expect(described_class.feed_url("1500000003")).to eq("https://feeds.example.com/tidepool.xml")
    end

    it "is nil when Apple doesn't know the show, lists no feed, or lists one that isn't http(s)" do
      stub_request(:get, lookup_url).to_return(status: 200, body: { resultCount: 0, results: [] }.to_json)
      expect(described_class.feed_url("1500000003")).to be_nil

      show = lookup["results"].first
      [ nil, "ftp://feeds.example.com/tidepool.xml", "javascript:alert(1)" ].each do |url|
        stub_request(:get, lookup_url).to_return(status: 200, body: lookup.merge("results" => [ show.merge("feedUrl" => url) ]).to_json)
        expect(described_class.feed_url("1500000003")).to be_nil
      end

      stub_request(:get, lookup_url).to_return(status: 200, body: lookup.merge("results" => [ show.merge("collectionId" => 1) ]).to_json)
      expect(described_class.feed_url("1500000003")).to be_nil
    end

    it "refuses an id that isn't one" do
      expect { described_class.feed_url("1&entity=x") }.to raise_error(ArgumentError)
    end
  end
end
