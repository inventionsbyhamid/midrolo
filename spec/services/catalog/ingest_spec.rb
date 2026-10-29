require "rails_helper"

RSpec.describe Catalog::Ingest do
  include ActiveJob::TestHelper

  let(:url) { "https://feeds.example.com/tidepool.xml" }
  let(:xml) { Rails.root.join("spec/fixtures/feeds/catalog_namespace.xml").binread }
  let(:podcast) { create(:podcast, title: "Tidepool", feed_url: url, source: "search") }

  before do
    travel_to Time.utc(2026, 10, 29, 12)
    allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ])
  end

  def feed_with(xml_text, etag: nil)
    stub_request(:get, url).to_return(status: 200, body: xml_text, headers: etag ? { "ETag" => etag } : {})
  end

  describe "a readable feed" do
    before { feed_with(xml, etag: %("v1")) }

    it "upserts the newest episodes with insert-only slugs, and stores the feed's facts" do
      outcome = described_class.call(podcast)

      expect(outcome.status).to eq(:updated)
      podcast.reload
      expect(podcast.episodes.newest_first.pluck(:guid)).to eq([ "tide-3", "tide-2", "tide-1", "https://traffic.libsyn.com/tidepool/trailer.mp3" ])
      episode = podcast.episodes.find_by(guid: "tide-3")
      expect(episode.slug).to eq("episode-3-anemones-up-close")
      expect([ episode.duration_seconds, episode.transcript_url ]).to eq([ 3723, "https://tidepool.example.com/3.vtt" ])

      expect(podcast.title).to eq("The Tidepool Hour")
      expect(podcast.slug).to eq("the-tidepool-hour")
      expect(podcast.author).to eq("Marina Reyes")
      expect(podcast.owner_email).to eq("marina@tidepool.example.com")
      expect(podcast.podcast_guid).to eq("917393e3-1b1e-5cef-ace4-edaa54e1f810")
      expect([ podcast.hosting_provider, podcast.measurement ]).to eq([ "libsyn", %w[op3 podtrac] ])
      expect([ podcast.episode_count, podcast.cadence_days ]).to eq([ 5, 14 ])
      expect(podcast.last_published_at).to eq(Time.utc(2026, 10, 20, 9))
      expect([ podcast.feed_etag, podcast.feed_sha256 ]).to eq([ %("v1"), Digest::SHA256.hexdigest(xml) ])
      expect([ podcast.fetch_failures, podcast.last_error, podcast.leased_until ]).to eq([ 0, nil, nil ])
    end

    it "is active, not indexable before its artwork is stored, and read again in 12 hours (last episode 9 days ago)" do
      described_class.call(podcast)
      podcast.reload

      expect(podcast).to be_active
      expect(podcast.indexable).to be(false)
      expect(podcast.next_fetch_at).to be_between(12.hours.from_now, (12.hours * 1.05).from_now)
    end

    it "is indexable once its artwork is stored, when a directory lists it" do
      podcast.update!(artwork_image: create(:image, :with_file), podcast_index_id: 77)
      described_class.call(podcast)
      expect(podcast.reload.indexable).to be(true)
    end

    it "stays noindex while a feed added by its URL alone is unclaimed (code review M4)" do
      podcast.update!(artwork_image: create(:image, :with_file))
      described_class.call(podcast)
      expect(podcast.reload.indexable).to be(false)
    end

    it "stores the people the feed names, counting their episodes, and drops anyone it stops naming" do
      create(:podcast_person, podcast: podcast, name: "Old Guest", role: "guest")
      described_class.call(podcast)

      people = podcast.people.order(:role, :name).map { |person| [ person.name, person.role, person.episodes_count ] }
      expect(people).to eq([ [ "Dr. Ana Lima", "guest", 2 ], [ "Marina Reyes", "host", 2 ], [ "Sam Ortiz", "other", 0 ] ])
      expect(podcast.people.find_by(name: "Marina Reyes").img_url).to eq("https://img.example.com/marina.jpg")
    end

    it "queues the artwork at the ingest's priority, and the sponsor scan of the new episodes only" do
      described_class.call(podcast, priority: 0)

      expect(Catalog::ArtworkJob).to have_been_enqueued.with(podcast.id).at_priority(0)
      new_ids = podcast.episodes.order(:id).pluck(:id)
      expect(Sponsors::ScanJob).to have_been_enqueued.with(podcast.id, match_array(new_ids))

      clear_enqueued_jobs
      feed_with(xml.sub("Episode 1:", "Episode One:"))
      described_class.call(podcast.reload)
      expect(Sponsors::ScanJob).not_to have_been_enqueued
    end

    it "keeps an episode's slug when its title changes, and never deletes episodes" do
      described_class.call(podcast)
      slug = podcast.episodes.find_by(guid: "tide-1").slug

      feed_with(xml.sub("Episode 1: Why tide pools matter", "Episode 1: Renamed").gsub(%r{<item>\s*<title>Trailer</title>.*?</item>}m, ""))
      described_class.call(podcast.reload)

      episode = podcast.episodes.find_by(guid: "tide-1")
      expect([ episode.title, episode.slug ]).to eq([ "Episode 1: Renamed", slug ])
      expect(podcast.episodes.count).to eq(4)
    end

    it "gives a new episode its title as its slug, with the guid suffix when another episode already has it" do
      create(:episode, podcast: podcast, guid: "older", title: "x", slug: "episode-1-why-tide-pools-matter")
      described_class.call(podcast)
      expect(podcast.episodes.find_by(guid: "tide-1").slug)
        .to eq("episode-1-why-tide-pools-matter-#{Digest::SHA256.hexdigest('tide-1').first(6)}")
      expect(podcast.episodes.find_by(guid: "tide-2").slug).to eq("episode-2-starfish-sea-stars")
    end

    it "gives two new episodes with one title different slugs" do
      feed_with(xml.sub("Episode 2: Starfish &amp; <i>sea stars</i>", "Episode 1: Why tide pools matter"))
      described_class.call(podcast)
      slugs = podcast.episodes.where(guid: %w[tide-1 tide-2]).pluck(:slug)
      expect(slugs.uniq.size).to eq(2)
      expect(slugs).to include("episode-1-why-tide-pools-matter")
    end
  end

  describe "an unchanged feed" do
    before do
      feed_with(xml, etag: %("v1"))
      described_class.call(podcast)
      podcast.reload
    end

    it "skips the parse on a 304, and on the same bytes, without touching the page" do
      updated_at = podcast.updated_at
      travel 1.hour
      stub_request(:get, url).with(headers: { "If-None-Match" => %("v1") }).to_return(status: 304)
      expect(Catalog::FeedParser).not_to receive(:call)

      expect(described_class.call(podcast).status).to eq(:unchanged)
      expect(podcast.reload.updated_at).to eq(updated_at)
      expect(podcast.feed_checked_at).to eq(Time.current)

      stub_request(:get, url).to_return(status: 200, body: xml)
      expect(described_class.call(podcast).status).to eq(:unchanged)
    end

    it "turns dormant as time passes, and touches the page when it does" do
      travel 100.days
      stub_request(:get, url).to_return(status: 304)
      described_class.call(podcast)

      expect(podcast.reload).to be_dormant
      expect(podcast.updated_at).to eq(Time.current)
      expect(podcast.next_fetch_at).to be > 7.days.from_now - 1.minute
    end
  end

  describe "a feed that fails" do
    it "counts the failure, keeps the error, backs off, and fails a podcast never read on its first" do
      stub_request(:get, url).to_return(status: 503)
      expect { described_class.call(podcast) }.not_to raise_error

      podcast.reload
      expect([ podcast.status, podcast.fetch_failures, podcast.last_error ]).to eq([ "failed", 1, "feed_server_error" ])
      # No episode date known: 7 days, the most a failure waits too.
      expect(podcast.next_fetch_at).to be_between(7.days.from_now, (7.days * 1.05).from_now)
    end

    it "fails a podcast that was read before only after 3 in a row, doubling the wait up to 7 days" do
      podcast.update!(status: "active", last_published_at: 2.days.ago, feed_sha256: "x")
      stub_request(:get, url).to_return(status: 404)

      described_class.call(podcast)
      expect([ podcast.reload.status, podcast.next_fetch_at ]).to match([ "active", be_within(1.hour).of(12.hours.from_now) ])
      described_class.call(podcast)
      expect(podcast.reload.status).to eq("active")
      described_class.call(podcast)
      expect([ podcast.reload.status, podcast.fetch_failures ]).to eq([ "failed", 3 ])
      expect(podcast.indexable).to be(false)

      feed_with(xml)
      described_class.call(podcast)
      expect([ podcast.reload.status, podcast.fetch_failures, podcast.last_error ]).to eq([ "active", 0, nil ])
    end

    # Review M7: a claimed show's host having a bad day (or a CDN refusing bots) mustn't take it out of the directory.
    it "keeps a claimed show listed when its feed fails, notes it, and mails the owner once after 3 in a row" do
      owner = create(:user, email: "host@example.com")
      create(:show, user: owner, podcast: podcast, verified_at: 1.day.ago)
      podcast.update!(status: "active", last_published_at: 2.days.ago, feed_sha256: "x", claimed_at: 1.day.ago)
      stub_request(:get, url).to_return(status: 403)

      expect { 2.times { described_class.call(podcast) } }.not_to have_enqueued_mail(ClaimMailer, :feed_unreachable)
      expect(podcast.reload).not_to be_feed_unreachable
      stamp = podcast.updated_at
      travel 1.minute
      expect { described_class.call(podcast) }.to have_enqueued_mail(ClaimMailer, :feed_unreachable).exactly(:once)
      expect { described_class.call(podcast) }.not_to have_enqueued_mail(ClaimMailer, :feed_unreachable)

      podcast.reload
      expect([ podcast.status, podcast.fetch_failures, podcast.last_error ]).to eq([ "active", 4, "feed_forbidden" ])
      expect(podcast).to be_feed_unreachable
      expect(podcast.updated_at).to be > stamp # the page's note shows, so its caches change
      expect(Podcast.listed).to include(podcast)

      feed_with(xml)
      described_class.call(podcast)
      expect(podcast.reload).not_to be_feed_unreachable
    end

    it "brings back a claimed show that had failed, as active or dormant, while an unclaimed one stays failed" do
      podcast.update!(status: "failed", last_published_at: 200.days.ago, fetch_failures: 3, claimed_at: 1.day.ago)
      unclaimed = create(:podcast, feed_url: "https://feeds.example.com/other.xml", status: "active", last_published_at: 2.days.ago,
                                   fetch_failures: 2)
      stub_request(:get, url).to_return(status: 500)
      stub_request(:get, unclaimed.feed_url).to_return(status: 500)

      described_class.call(podcast)
      described_class.call(unclaimed)
      expect(podcast.reload.status).to eq("dormant")
      expect(unclaimed.reload.status).to eq("failed")
      expect(Podcast.listed).to contain_exactly(podcast)
    end

    it "records broken XML as unparseable" do
      feed_with(Rails.root.join("spec/fixtures/feeds/catalog_broken.xml").binread)
      expect(described_class.call(podcast).error).to eq("feed_unparseable")
      expect(podcast.reload.last_error).to eq("feed_unparseable")
    end

    it "records a redirect loop" do
      stub_request(:get, url).to_return(status: 301, headers: { "Location" => "https://feeds.example.com/other.xml" })
      stub_request(:get, "https://feeds.example.com/other.xml").to_return(status: 301, headers: { "Location" => url })
      described_class.call(podcast)
      expect(podcast.reload.last_error).to eq("feed_redirect_loop")
    end

    it "reports an unexpected error and backs off instead of raising" do
      feed_with(xml)
      allow(Catalog::FeedParser).to receive(:call).and_raise(NoMethodError, "boom")
      expect(Rails.error).to receive(:report).with(instance_of(NoMethodError), hash_including(handled: true))

      expect(described_class.call(podcast).error).to eq("ingest_error")
      expect(podcast.reload.fetch_failures).to eq(1)
    end
  end

  describe "removal" do
    it "removes a podcast whose feed asks not to be listed" do
      feed_with(Rails.root.join("spec/fixtures/feeds/catalog_blocked.xml").binread)
      described_class.call(podcast)

      podcast.reload
      expect([ podcast.status, podcast.indexable, podcast.next_fetch_at, podcast.last_error ]).to eq([ "removed", false, nil, "feed_blocked_by_show" ])
      expect(podcast.episodes).to be_empty
    end

    it "removes a suppressed podcast, by feed URL or by the guid its feed carries, without storing anything" do
      Suppression.create!(kind: "podcast", value: Suppression.feed_digest(url))
      expect(described_class.call(podcast).status).to eq(:removed)
      expect(a_request(:get, url)).not_to have_been_made

      other = create(:podcast, feed_url: "https://feeds.example.com/other.xml")
      stub_request(:get, other.feed_url).to_return(status: 200, body: xml)
      Suppression.create!(kind: "podcast", value: "917393e3-1b1e-5cef-ace4-edaa54e1f810")
      described_class.call(other)
      expect(other.reload).to be_removed
      expect(other.episodes).to be_empty
    end
  end

  describe "one show under two feed URLs" do
    it "leaves the podcast:guid with the podcast that had it first" do
      create(:podcast, podcast_guid: "917393e3-1b1e-5cef-ace4-edaa54e1f810")
      feed_with(xml)
      described_class.call(podcast)
      expect(podcast.reload.podcast_guid).to be_nil
    end

    it "moves the feed URL when the feed moved for good and no other podcast has the new one" do
      stub_request(:get, url).to_return(status: 301, headers: { "Location" => "https://new.example.com/feed.xml" })
      stub_request(:get, "https://new.example.com/feed.xml").to_return(status: 200, body: xml)
      described_class.call(podcast)
      expect(podcast.reload.feed_url).to eq("https://new.example.com/feed.xml")

      taken = create(:podcast, feed_url: "https://newer.example.com/feed.xml")
      feed_with(xml.sub("<link>https://tidepool.example.com/</link>",
                        "<link>https://tidepool.example.com/</link><itunes:new-feed-url>#{taken.feed_url}</itunes:new-feed-url>"))
      other = create(:podcast, feed_url: url)
      described_class.call(other)
      expect(other.reload.feed_url).to eq(url)
    end
  end

  # Code review H1: a claim proves control of the feed at claim time, so a feed move must not carry it onto a feed the
  # owner never proved (a claimed decoy pointing itunes:new-feed-url at a real show's feed).
  describe "a claimed podcast whose feed moves" do
    let(:owner) { create(:user, email: "decoy@example.com") }
    let!(:owner_show) { create(:show, user: owner, podcast: podcast) }
    let(:real_feed) { "https://real.example.com/feed.xml" }

    before do
      create(:media_kit, :published, show: owner_show, open_to_sponsors: true, rate_card_overrides: { "midroll" => "300" })
      podcast.record_provided_downloads!(4_000)
      create(:stat_reading, podcast: podcast, source: "spotify", trust: "verified", metric: "followers", value: 50)
    end

    def moved_xml(to) = xml.sub("<link>https://tidepool.example.com/</link>",
                                "<link>https://tidepool.example.com/</link><itunes:new-feed-url>#{to}</itunes:new-feed-url>")

    it "releases the claim on itunes:new-feed-url, records the move, and asks the owner to verify the new feed" do
      expect(podcast.reload).to have_attributes(claimed_at: be_present, open_to_sponsors: true, downloads_per_episode: 4_000)
      feed_with(moved_xml(real_feed))

      expect { described_class.call(podcast) }.to have_enqueued_mail(ClaimMailer, :feed_moved)

      podcast.reload
      expect(podcast.feed_url).to eq(real_feed)
      expect(owner_show.reload.verified_at).to be_nil
      expect(podcast).to have_attributes(claimed_at: nil, open_to_sponsors: false, min_price_cents: nil,
                                         downloads_per_episode: nil, downloads_trust: nil)
      expect(podcast.owner_show).to be_nil
      expect(podcast.stat_readings).to be_empty
      expect(podcast.next_fetch_at).to be > 2.hours.from_now # no longer read hourly as a claimed show
      expect(podcast.feed_moves.sole).to have_attributes(from_url: url, to_url: real_feed, via: "new_feed_url",
                                                         released_show: owner_show)
    end

    it "lets the real show's host claim the moved page, after which the decoy can't take it back" do
      feed_with(moved_xml(real_feed))
      described_class.call(podcast)

      host = create(:show, user: create(:user), podcast: podcast.reload)
      expect { host.verify!(via: "email") }.not_to raise_error
      expect(podcast.reload.owner_show).to eq(host)
      expect { owner_show.reload.verify!(via: "email") }.to raise_error(Show::AlreadyClaimed)
    end

    it "releases it on a permanent redirect too" do
      stub_request(:get, url).to_return(status: 308, headers: { "Location" => real_feed })
      stub_request(:get, real_feed).to_return(status: 200, body: xml)

      described_class.call(podcast)

      expect(podcast.reload).to have_attributes(feed_url: real_feed, claimed_at: nil)
      expect(owner_show.reload.verified_at).to be_nil
      expect(podcast.feed_moves.sole.via).to eq("redirect")
    end

    it "keeps the claim when the feed stays put, or names a URL another podcast already has" do
      create(:podcast, feed_url: real_feed)
      feed_with(moved_xml(real_feed))

      expect { described_class.call(podcast) }.not_to have_enqueued_mail(ClaimMailer, :feed_moved)
      expect(podcast.reload).to have_attributes(feed_url: url, claimed_at: be_present, downloads_per_episode: 4_000)
      expect(owner_show.reload.verified_at).to be_present
      expect(PodcastFeedMove.count).to eq(0)
    end

    it "records an unclaimed podcast's move without anyone to tell" do
      owner_show.update!(verified_at: nil)
      podcast.update!(claimed_at: nil)
      feed_with(moved_xml(real_feed))

      expect { described_class.call(podcast) }.not_to have_enqueued_mail(ClaimMailer, :feed_moved)
      expect(podcast.feed_moves.sole).to have_attributes(to_url: real_feed, released_show: nil)
    end
  end

  it "keeps the larger episode count and older first date when only the top of a huge feed was read" do
    podcast.update!(episode_count: 900, first_published_at: Time.utc(2015, 1, 1))
    stub_const("Catalog::FeedFetcher::MAX_BYTES", 2_500)
    feed_with(xml)
    described_class.call(podcast)

    podcast.reload
    expect([ podcast.episode_count, podcast.first_published_at ]).to eq([ 900, Time.utc(2015, 1, 1) ])
    expect(podcast.episodes.pluck(:guid)).to eq([ "tide-1" ])
  end

  it "ingests a demo directory feed offline" do
    demo = create(:podcast, title: "Placeholder", feed_url: "fake://fake-1")
    described_class.call(demo)

    demo.reload
    expect([ demo.title, demo.owner_email, demo.cadence_days ]).to eq([ "The Founder's Ledger", "host@the-founder-s-ledger.example", 7 ])
    expect(demo.episodes.count).to eq(demo.episode_count)
    expect(demo.people.pluck(:name)).to eq([ "Maya Brandt" ])
  end
end
