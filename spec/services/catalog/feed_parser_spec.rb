require "rails_helper"

RSpec.describe Catalog::FeedParser do
  let(:now) { Time.utc(2026, 10, 29, 12) }

  def fixture(name) = Rails.root.join("spec/fixtures/feeds/#{name}").binread

  def parse(name, feed_url: "https://feeds.example.com/tidepool.xml")
    described_class.call(fixture(name), feed_url: feed_url, now: now)
  end

  describe "a podcast namespace feed" do
    subject(:feed) { parse("catalog_namespace.xml") }

    it "reads the channel as plain text, links through Show.http_url" do
      expect(feed.title).to eq("The Tidepool Hour")
      expect(feed.description).to eq("A made-up show about tide pools & the people who study them.\nNew every other Monday.")
      expect(feed.author).to eq("Marina Reyes")
      expect(feed.language).to eq("en-us")
      expect([ feed.explicit, feed.itunes_type ]).to eq([ false, "episodic" ])
      expect(feed.categories).to eq(%w[Science Nature Education])
      expect(feed.website).to eq("https://tidepool.example.com/")
      expect(feed.artwork_url).to eq("https://img.example.com/tidepool.jpg")
      expect(feed.owner_email).to eq("marina@tidepool.example.com")
    end

    it "reads the podcast namespace: guid, locked, medium, txt, funding, and a block for one platform only" do
      expect(feed.podcast_guid).to eq("917393e3-1b1e-5cef-ace4-edaa54e1f810")
      expect([ feed.locked, feed.blocked, feed.medium ]).to eq([ true, false, "podcast" ])
      expect(feed.txt).to eq([ "midrolo-verify=abc123" ])
      expect(feed.funding.map(&:to_h)).to eq([ { url: "https://tidepool.example.com/support", text: "Support the show" } ])
    end

    it "names the channel's people, keeping only http(s) links" do
      expect(feed.people.map(&:to_h)).to eq([
        { name: "Marina Reyes", role: "host", href: "https://tidepool.example.com/marina", img_url: "https://img.example.com/marina.jpg" },
        { name: "Sam Ortiz", role: "other", href: nil, img_url: nil }
      ])
    end

    it "keeps the newest episodes first, one per guid, with a guid for every one" do
      expect(feed.episodes.map(&:guid)).to eq([ "tide-3", "tide-2", "tide-1", "https://traffic.libsyn.com/tidepool/trailer.mp3" ])
      expect(feed.episode_count).to eq(5)
      expect(feed.first_published_at).to eq(Time.utc(2026, 9, 15, 9))
      expect(feed.last_published_at).to eq(Time.utc(2026, 10, 20, 9))
      expect(feed.cadence_days).to eq(14)
    end

    it "reads each episode's text, numbers, links and people" do
      newest = feed.episodes.first
      expect(newest.title).to eq("Episode 3: Anemones up close")
      expect(newest.description).to eq("Dr. Ana Lima joins Marina.\nThis episode is sponsored by Kelpwise. Use code TIDE for 20% off at kelpwise.example.com.")
      expect([ newest.duration_seconds, newest.season, newest.number, newest.episode_type ]).to eq([ 3723, 2, 3, "full" ])
      expect(newest.transcript_url).to eq("https://tidepool.example.com/3.vtt")
      expect(newest.link).to eq("https://tidepool.example.com/3")
      expect(newest.people.map { |person| [ person.name, person.role ] }).to eq([ [ "Marina Reyes", "host" ], [ "Dr. Ana Lima", "guest" ] ])

      second = feed.episodes.second
      expect(second.title).to eq("Episode 2: Starfish & sea stars")
      expect([ second.duration_seconds, second.link ]).to eq([ 2730, nil ])
      expect(feed.episodes.last.episode_type).to eq("trailer")
    end

    it "detects the host and the measurement prefixes from the enclosures" do
      expect(feed.hosting_provider).to eq("libsyn")
      expect(feed.measurement).to eq(%w[op3 podtrac])
    end
  end

  it "keeps only the newest 50 episodes" do
    items = Array.new(60) do |i|
      "<item><title>E#{i}</title><guid>g#{i}</guid><pubDate>#{(now - i.days).rfc2822}</pubDate></item>"
    end
    feed = described_class.call(%(<rss version="2.0"><channel><title>Many</title>#{items.join}</channel></rss>), now: now)
    expect(feed.episodes.size).to eq(50)
    expect(feed.episodes.first.guid).to eq("g0")
    expect(feed.episode_count).to eq(60)
    expect(feed.first_published_at).to eq(now - 59.days)
  end

  it "reads an old Latin-1 feed with an undeclared itunes prefix, no guids and a bad date" do
    feed = parse("catalog_minimal.xml", feed_url: "http://cafe.example.com/feed")
    expect(feed.title).to eq("Café Chats")
    expect(feed.description).to eq("Talk over coffee at the café.")
    expect(feed.author).to eq("Renée Blanc")
    expect(feed.owner_email).to eq("renee@cafe.example.com")
    expect(feed.episodes.map(&:guid)).to eq([ "http://cafe.example.com/1", "http://cafe.example.com/2.mp3" ])
    expect(feed.episodes.map(&:published_at)).to eq([ Time.utc(2026, 8, 1, 10), nil ])
    expect(feed.cadence_days).to be_nil
  end

  it "sees itunes:block as a request not to be listed" do
    expect(parse("catalog_blocked.xml").blocked).to be(true)
  end

  it "raises Unreadable for broken XML, an HTML page, an Atom feed or nothing" do
    expect { parse("catalog_broken.xml") }.to raise_error(described_class::Unreadable, "feed_unparseable")
    expect { parse("invalid.xml") }.to raise_error(described_class::Unreadable, "feed_unparseable")
    expect { described_class.call(%(<feed xmlns="http://www.w3.org/2005/Atom"><title>A</title></feed>)) }
      .to raise_error(described_class::Unreadable)
    expect { described_class.call(" ") }.to raise_error(described_class::Unreadable, "feed_empty")
  end

  it "never lets a link that isn't http(s), a far future date or a silly duration through" do
    xml = <<~XML
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>T</title>
        <link>javascript:alert(1)</link><itunes:image href="data:image/png;base64,AAAA"/>
        <item><title>E</title><guid>e</guid><pubDate>Tue, 01 Jan 2999 00:00:00 GMT</pubDate>
          <itunes:duration>999:00:00</itunes:duration><enclosure url="file:///etc/passwd"/></item>
      </channel></rss>
    XML
    feed = described_class.call(xml, now: now)
    expect([ feed.website, feed.artwork_url ]).to eq([ nil, nil ])
    episode = feed.episodes.first
    expect([ episode.published_at, episode.duration_seconds, episode.enclosure_url ]).to eq([ nil, nil, nil ])
  end
end
