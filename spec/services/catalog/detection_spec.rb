require "rails_helper"

RSpec.describe Catalog::Detection do
  describe ".unwrap" do
    it "takes chained measurement prefixes off, outermost first, with or without the inner scheme" do
      vendors, rest = described_class.unwrap("https://op3.dev/e/dts.podtrac.com/redirect.mp3/traffic.libsyn.com/show/1.mp3")
      expect([ vendors, rest ]).to eq([ %w[op3 podtrac], "https://traffic.libsyn.com/show/1.mp3" ])

      vendors, rest = described_class.unwrap("https://op3.dev/e,pg=917393e3/https://chrt.fm/track/AB12C/cdn.simplecast.com/a.mp3")
      expect([ vendors, rest ]).to eq([ %w[op3 chartable], "https://cdn.simplecast.com/a.mp3" ])

      expect(described_class.unwrap("https://pdst.fm/e/verifi.podscribe.com/rss/p/mgln.ai/e/42/x.example.com/a.mp3").first)
        .to eq(%w[spotify podscribe magellan])
    end

    it "leaves a plain URL alone" do
      expect(described_class.unwrap("https://media.example.com/a.mp3")).to eq([ [], "https://media.example.com/a.mp3" ])
    end
  end

  describe ".measurement" do
    it "lists every vendor found on any URL, in config order" do
      urls = [ "https://dts.podtrac.com/redirect.mp3/a.example.com/1.mp3", "https://op3.dev/e/a.example.com/2.mp3", nil ]
      expect(described_class.measurement(urls)).to eq(%w[op3 podtrac])
    end
  end

  describe ".hosting_provider" do
    it "is the provider most enclosures are served from, prefixes off" do
      urls = [ "https://op3.dev/e/traffic.libsyn.com/a/1.mp3", "https://traffic.libsyn.com/a/2.mp3",
               "https://media.transistor.fm/x/3.mp3" ]
      expect(described_class.hosting_provider(urls)).to eq("libsyn")
    end

    it "falls back to the feed URL's host, and is nil for an unknown host" do
      expect(described_class.hosting_provider([ "https://cdn.example.com/1.mp3" ], feed_url: "https://feeds.buzzsprout.com/1.rss"))
        .to eq("buzzsprout")
      expect(described_class.hosting_provider([ "https://cdn.example.com/1.mp3" ], feed_url: "https://example.com/feed")).to be_nil
      expect(described_class.hosting_provider([], feed_url: "not a url")).to be_nil
    end

    it "matches a whole domain, not a lookalike" do
      expect(described_class.provider_for_host("anchor.fm")).to eq("spotify")
      expect(described_class.provider_for_host("evilanchor.fm")).to be_nil
    end
  end

  it "names providers and vendors for people" do
    expect([ described_class.provider_name("libsyn"), described_class.vendor_name("op3") ]).to eq([ "Libsyn", "OP3" ])
    expect(described_class.provider_name(nil)).to be_nil
  end
end
