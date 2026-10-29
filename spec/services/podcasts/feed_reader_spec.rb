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

  describe "episode text" do
    def one_item_feed(description_html)
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Text Show</title>
          <item><title>Ep 1</title><description><![CDATA[#{description_html}]]></description>
          <pubDate>Mon, 12 Oct 2026 09:00:00 -0000</pubDate><guid>text-1</guid></item>
        </channel></rss>
      XML
    end

    it "keeps block elements apart instead of running their text together" do
      html = "<p>Sponsored by Notion</p><p>Visit Today</p><ul><li>One</li><li>Two</li></ul>Line<br>break<h2>Head</h2><div>Tail</div>"
      stub_request(:get, url).to_return(status: 200, body: one_item_feed(html))

      expect(reader.read(url).episodes.first.description).to eq("Sponsored by Notion\nVisit Today\nOne\nTwo\nLine\nbreak\nHead\nTail")
    end

    it "turns non-breaking and other Unicode spaces into plain spaces and drops spacer lines" do
      html = "<p>This episode is sponsored by&nbsp;Rocket&nbsp;Money.</p><p>&nbsp;</p><p>Use code PODS at&nbsp;acme.com&#8195;today</p>"
      stub_request(:get, url).to_return(status: 200, body: one_item_feed(html).sub("<title>Ep 1</title>", "<title>Ep&#160;1&#160;</title>"))
      episode = reader.read(url).episodes.first

      expect(episode.description).to eq("This episode is sponsored by Rocket Money.\nUse code PODS at acme.com today")
      expect(episode.title).to eq("Ep 1")
      expect(episode.description + episode.title).not_to include(" ")
    end

    it "truncates descriptions to 600 characters by default" do
      stub_request(:get, url).to_return(status: 200, body: one_item_feed("<p>#{'filler ' * 150}</p><p>This episode is sponsored by Notion.</p>"))
      description = reader.read(url).episodes.first.description

      expect(description.length).to eq(600)
      expect(description).not_to include("Notion")
    end

    it "takes a larger description_limit and caches it separately" do
      stub_request(:get, url).to_return(status: 200, body: one_item_feed("<p>#{'filler ' * 150}</p><p>This episode is sponsored by Notion.</p>"))

      short = reader.read(url).episodes.first.description
      long = reader.read(url, description_limit: 4000).episodes.first.description
      expect(short.length).to eq(600)
      expect(long).to end_with("This episode is sponsored by Notion.")
      expect(a_request(:get, url)).to have_been_made.twice
      reader.read(url, description_limit: 4000)
      expect(a_request(:get, url)).to have_been_made.twice
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

    it "flags a body over 5 MB with no whole episode in its first 5 MB" do
      stub_request(:get, url).to_return(status: 200, body: "x" * (5 * 1024 * 1024 + 1))
      feed = reader.read(url)
      expect(feed.episodes).to eq([])
      expect(feed.warnings).to eq([ "feed_too_large" ])
    end

    it "reads the newest episodes of a feed over 5 MB from its first 5 MB, cut after the last whole episode" do
      item = ->(n) { "<item><title>Episode #{n}</title><guid>ep-#{n}</guid><description>#{'Sponsored by Notion. ' * 50}</description></item>" }
      items = (1..6000).map { |n| item.(n) }.join
      body = %(<?xml version="1.0"?><rss version="2.0"><channel><title>Long Show</title>#{items}</channel></rss>)
      expect(body.bytesize).to be > 5 * 1024 * 1024
      stub_request(:get, url).to_return(status: 200, body: body)

      feed = reader.read(url, max_episodes: 3)

      expect(feed.warnings).to eq([])
      expect(feed.title).to eq("Long Show")
      expect(feed.episodes.map(&:title)).to eq([ "Episode 1", "Episode 2", "Episode 3" ])
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

  describe "channel fields for ownership checks" do
    def channel_feed(inner)
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Token Show</title>#{inner}
          <item><title>Ep 1</title><pubDate>Mon, 12 Oct 2026 09:00:00 -0000</pubDate><guid>t-1</guid></item>
        </channel></rss>
      XML
    end

    it "reads podcast:txt values and the channel link" do
      stub_request(:get, url).to_return(status: 200, body: channel_feed(<<~XML))
        <link>https://tokenshow.example.com/</link>
        <podcast:txt purpose="verify">midrolo-verify=abc123</podcast:txt>
        <podcast:txt>another note</podcast:txt>
      XML
      feed = reader.read(url)

      expect(feed.txt).to eq([ "midrolo-verify=abc123", "another note" ])
      expect(feed.website).to eq("https://tokenshow.example.com/")
    end

    it "caps the channel description at description_limit" do
      stub_request(:get, url).to_return(status: 200, body: channel_feed("<description>#{'filler ' * 150} midrolo-verify=late</description>"))

      expect(reader.read(url).description).not_to include("midrolo-verify=late")
      expect(reader.read(url, description_limit: 4000).description).to end_with("midrolo-verify=late")
    end

    it "leaves txt empty and website nil when the feed has neither" do
      stub_request(:get, url).to_return(status: 200, body: channel_feed(""))
      feed = reader.read(url)
      expect([ feed.txt, feed.website ]).to eq([ [], nil ])
    end
  end

  describe "fresh reads" do
    before do
      stub_request(:get, url).to_return({ status: 200, body: feed_fixture("normal") },
                                        { status: 200, body: feed_fixture("normal").sub("The Widget Hour", "The Widget Hour Live") })
    end

    it "skips the cached copy, asks upstream caches for a fresh one and refreshes the cache" do
      expect(reader.read(url).title).to eq("The Widget Hour")
      expect(reader.read(url, fresh: true).title).to eq("The Widget Hour Live")
      expect(a_request(:get, url).with(headers: { "Cache-Control" => "no-cache" })).to have_been_made.once

      expect(reader.read(url).title).to eq("The Widget Hour Live") # the same key now holds the fresh copy
      expect(a_request(:get, url)).to have_been_made.twice
    end

    it "keeps the SSRF guard" do
      feed = reader.read("http://169.254.169.254/latest", fresh: true)
      expect(feed.warnings).to eq([ "feed_blocked" ])
      expect(a_request(:get, %r{169\.254})).not_to have_been_made
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
