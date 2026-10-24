require "rails_helper"

RSpec.describe Podcasts::FeedReader do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:reader) { described_class.new(cache: cache) }
  let(:url) { "https://widgethour.example.com/feed.xml" }

  before { allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ]) }

  def feed_fixture(name) = Rails.root.join("spec/fixtures/feeds/#{name}.xml").binread

  describe "a normal feed" do
    before { stub_request(:get, url).to_return(status: 200, body: feed_fixture("normal")) }

    it "parses episodes, owner and cadence" do
      feed = reader.read(url)
      expect(feed.title).to eq("The Widget Hour")
      expect(feed.episodes.size).to eq(20)
      expect(feed.owner_email).to eq("host@widgethour.example.com")
      expect(feed.owner_name).to eq("Wanda Widget")
      expect(feed.cadence_days).to eq(7)
      expect(feed.warnings).to eq([])
      expect(feed.episodes.first).to be_a(Podcasts::EpisodeInfo)
      expect(feed.episodes.first.guid).to eq("widget-ep-20")
    end

    it "respects max_episodes" do
      expect(reader.read(url, max_episodes: 5).episodes.size).to eq(5)
    end

    it "strips HTML and truncates descriptions to 600 chars" do
      eps = reader.read(url).episodes
      expect(eps.first.description.length).to be <= 600
      expect(eps.last.description).to eq("We talk about widgets & gadgets in installment 1.")
      expect(eps.map(&:description).join).not_to include("<")
    end

    it "caches successful reads" do
      2.times { reader.read(url) }
      expect(a_request(:get, url)).to have_been_made.once
    end
  end

  describe "thin feeds" do
    it "handles episodes without descriptions and falls back to managingEditor" do
      stub_request(:get, url).to_return(status: 200, body: feed_fixture("no_descriptions"))
      feed = reader.read(url)
      expect(feed.episodes.size).to eq(2)
      expect(feed.episodes.map(&:description)).to all(eq(""))
      expect(feed.owner_email).to eq("quiet@quiet.example.com")
      expect(feed.warnings).to eq([])
    end
  end

  describe "failures never raise" do
    it "flags invalid XML" do
      stub_request(:get, url).to_return(status: 200, body: feed_fixture("invalid"))
      feed = reader.read(url)
      expect(feed.episodes).to eq([])
      expect(feed.warnings).to eq([ "feed_unreadable" ])
    end

    it "flags a timeout" do
      stub_request(:get, url).to_timeout
      feed = reader.read(url)
      expect(feed.episodes).to eq([])
      expect(feed.warnings).to eq([ "feed_timeout" ])
    end

    it "flags a non-200 status" do
      stub_request(:get, url).to_return(status: 404, body: "nope")
      expect(reader.read(url).warnings).to eq([ "feed_unreadable" ])
    end

    it "flags a connection failure" do
      stub_request(:get, url).to_raise(Faraday::ConnectionFailed.new("boom"))
      expect(reader.read(url).warnings).to eq([ "feed_unreadable" ])
    end

    it "flags a body over 5 MB while streaming" do
      stub_request(:get, url).to_return(status: 200, body: "x" * (5 * 1024 * 1024 + 1))
      feed = reader.read(url)
      expect(feed.episodes).to eq([])
      expect(feed.warnings).to eq([ "feed_too_large" ])
    end

    it "flags a blank or non-http url" do
      expect(reader.read("").warnings).to eq([ "feed_blocked" ])
      expect(reader.read("file:///etc/passwd").warnings).to eq([ "feed_blocked" ])
    end

    it "does not cache failures" do
      stub_request(:get, url).to_return({ status: 500 }, { status: 200, body: feed_fixture("normal") })
      expect(reader.read(url).warnings).to eq([ "feed_unreadable" ])
      expect(reader.read(url).episodes.size).to eq(20)
    end
  end

  describe "SSRF guard" do
    %w[http://127.0.0.1/feed http://localhost/feed http://10.0.0.5/x http://169.254.169.254/latest
       http://[::1]/feed http://[::ffff:127.0.0.1]/feed http://0.0.0.0/x http://[fe80::1]/x http://[fc00::1]/x
       http://192.168.1.1/x http://172.16.0.1/x ftp://widgethour.example.com/feed
       https://widgethour.example.com:8080/feed].each do |blocked|
      it "blocks #{blocked} without any HTTP request" do
        allow(Resolv).to receive(:getaddresses).with("localhost").and_return([ "127.0.0.1" ])
        feed = reader.read(blocked)
        expect(feed.episodes).to eq([])
        expect(feed.warnings).to eq([ "feed_blocked" ])
        expect(a_request(:any, /.*/)).not_to have_been_made
      end
    end

    %w[http://2130706433/ http://0x7f.1/ http://127.1/ http://0177.0.0.1/ http://[::ffff:7f00:1]/
       http://a@127.0.0.1/ http://user:pw@localhost/x].each do |blocked|
      it "blocks #{blocked} without any HTTP request" do
        allow(Resolv).to receive(:getaddresses).with("localhost").and_return([ "127.0.0.1" ])
        feed = reader.read(blocked)
        expect(feed.warnings).to eq([ "feed_blocked" ])
        expect(feed.episodes).to eq([])
        expect(a_request(:any, /.*/)).not_to have_been_made
      end
    end

    it "blocks numeric hosts even when DNS would return a public address" do
      allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ])
      expect(reader.read("http://2130706433/").warnings).to eq([ "feed_blocked" ])
    end

    it "blocks when the host does not resolve (empty answer)" do
      allow(Resolv).to receive(:getaddresses).with("nope.example.com").and_return([])
      expect(reader.read("https://nope.example.com/f").warnings).to eq([ "feed_blocked" ])
    end

    it "blocks when DNS resolution raises" do
      allow(Resolv).to receive(:getaddresses).with("boom.example.com").and_raise(Resolv::ResolvError)
      expect(reader.read("https://boom.example.com/f").warnings).to eq([ "feed_blocked" ])
    end

    it "resolves a relative Location against the current URL and re-checks it" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "/moved.xml" })
      stub_request(:get, "https://widgethour.example.com/moved.xml").to_return(status: 200, body: feed_fixture("normal"))
      expect(reader.read(url).episodes.size).to eq(20)
    end

    it "blocks a relative-looking redirect that lands on an internal host" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "//127.0.0.1/x" })
      expect(reader.read(url).warnings).to eq([ "feed_blocked" ])
      expect(a_request(:get, %r{127\.0\.0\.1})).not_to have_been_made
    end

    it "gives feed_unreadable for a redirect loop without looping forever" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => url })
      feed = reader.read(url)
      expect(feed.warnings).to eq([ "feed_unreadable" ])
      expect(a_request(:get, url)).to have_been_made.times(4)
    end

    it "gives feed_unreadable after more than 3 hops" do
      (0..5).each { |i| stub_request(:get, "https://h#{i}.example.com/f").to_return(status: 301, headers: { "Location" => "https://h#{i + 1}.example.com/f" }) }
      feed = reader.read("https://h0.example.com/f")
      expect(feed.warnings).to eq([ "feed_unreadable" ])
      expect(a_request(:get, "https://h4.example.com/f")).not_to have_been_made
    end

    it "blocks a host that resolves to any private address" do
      allow(Resolv).to receive(:getaddresses).with("sneaky.example.com").and_return([ "93.184.216.34", "10.1.2.3" ])
      expect(reader.read("https://sneaky.example.com/feed").warnings).to eq([ "feed_blocked" ])
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "blocks a public host that redirects to a private IP" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "http://169.254.169.254/latest" })
      feed = reader.read(url)
      expect(feed.warnings).to eq([ "feed_blocked" ])
      expect(a_request(:get, "http://169.254.169.254/latest")).not_to have_been_made
    end

    it "follows a redirect to another public host" do
      stub_request(:get, url).to_return(status: 301, headers: { "Location" => "https://cdn.example.com/f.xml" })
      stub_request(:get, "https://cdn.example.com/f.xml").to_return(status: 200, body: feed_fixture("normal"))
      expect(reader.read(url).episodes.size).to eq(20)
    end
  end

  describe "encoding" do
    it "transcodes ISO-8859-1 input to UTF-8" do
      xml = <<~X.encode("ISO-8859-1")
        <?xml version="1.0" encoding="ISO-8859-1"?>
        <rss version="2.0"><channel><title>Café Show</title>
        <item><title>Crème brûlée</title><description>délicieux</description><pubDate>Mon, 28 Sep 2026 09:00:00 +0000</pubDate><guid>c1</guid></item>
        </channel></rss>
      X
      stub_request(:get, url).to_return(status: 200, body: xml.b)
      feed = reader.read(url)
      expect(feed.title).to eq("Café Show")
      expect(feed.episodes.first.title).to eq("Crème brûlée")
      expect(feed.episodes.first.description).to eq("délicieux")
      expect(feed.episodes.first.title.encoding).to eq(Encoding::UTF_8)
    end

    it "survives invalid bytes with no declared encoding" do
      xml = "<rss version=\"2.0\"><channel><title>Bad \xFF Byte</title><item><title>t</title><guid>g</guid></item></channel></rss>".b
      stub_request(:get, url).to_return(status: 200, body: xml)
      expect { reader.read(url) }.not_to raise_error
    end
  end

  describe "fake:// feeds" do
    it "returns canned episodes without HTTP" do
      feed = reader.read("fake://fake-1")
      expect(feed.episodes.size).to be_between(15, 20)
      expect(feed.owner_email).to end_with(".example")
      expect(feed.cadence_days).to eq(7)
    end

    it "returns an unreadable feed for an unknown fake id" do
      expect(reader.read("fake://fake-999").warnings).to eq([ "feed_unreadable" ])
    end
  end
end
