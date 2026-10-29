require "rails_helper"

RSpec.describe ShareImages::PodcastCard do
  let(:podcast) do
    create(:podcast, :indexable, :with_artwork, title: "Darknet Diaries", author: "Jack Rhysider",
                                                categories: [ "Technology", "News" ], episode_count: 192)
  end

  # Each <text>'s words; a title's lines (tspans) joined with a space.
  def texts(card)
    Nokogiri::XML(card.layout(artwork: :image).svg) { |config| config.strict }.css("text").map do |node|
      node.css("tspan").any? ? node.css("tspan").map(&:text).join(" ") : node.text
    end
  end

  def verified(metric, value, source: "spotify", **attributes)
    create(:stat_reading, podcast: podcast, metric: metric, value: value, source: source, trust: "verified",
                          captured_at: Time.utc(2026, 10, 29, 9), expires_at: 40.days.from_now, **attributes)
  end

  around { |example| travel_to(Time.utc(2026, 10, 30, 12)) { example.run } }

  it "shows the title, host and first category, and the episode count from the feed for a show nobody claimed" do
    shown = texts(described_class.new(podcast))

    expect(shown).to include("Podcast", "Darknet Diaries", "Hosted by Jack Rhysider · Technology", "192", "episodes",
                             "From the show's RSS feed")
    expect(shown).not_to include("Stats verified", "Open to sponsors")
    expect(shown.join(" ")).not_to match(/[–—]/)
  end

  it "shows no readings before a claim, even when some exist" do
    verified("listeners_30d", 2_140)
    expect(texts(described_class.new(podcast))).not_to include("Stats verified", "2.1K")
  end

  context "when the show is claimed" do
    before { podcast.update!(claimed_at: 1.day.ago) }

    it "shows one verified number with its platform, period, service and date, and the Stats verified mark" do
      verified("streams_30d", 9_000)
      verified("listeners_30d", 2_140)
      shown = texts(described_class.new(podcast.reload))

      expect(shown).to include("Stats verified", "2.1K", "Spotify listeners, 30 days",
                               "Verified with Spotify for Creators · Oct 29")
      expect(shown).not_to include("9K", "episodes")
    end

    it "prefers the per-episode figure" do
      verified("listeners_30d", 2_140)
      verified(StatReading::DOWNLOADS_PER_EPISODE, 840, source: Podcast::Stats::PLAYS_SOURCE, evidence: { "sources" => [ "spotify" ] })
      shown = texts(described_class.new(podcast.reload))

      expect(shown).to include("840", "Spotify plays per episode, 30 days")
    end

    it "says a provided number came from the show, without the verified mark" do
      create(:stat_reading, podcast: podcast, value: 4_200, captured_at: Time.utc(2026, 10, 20), expires_at: nil)
      shown = texts(described_class.new(podcast.reload))

      expect(shown).to include("4.2K", "Downloads per episode", "Provided by the show · Oct 20")
      expect(shown).not_to include("Stats verified")
    end

    it "shows the owner's band instead of the number when the listing asks for bands" do
      owner = create(:show, podcast: podcast)
      create(:media_kit, :published, show: owner, bands_only: true)
      verified("listeners_30d", 2_140)

      expect(texts(described_class.new(podcast.reload))).to include("1,000 to 2,500", "Spotify listeners, 30 days")
    end

    it "leaves expired numbers out and falls back to the feed" do
      verified("listeners_30d", 2_140, expires_at: 1.day.ago)
      shown = texts(described_class.new(podcast.reload))

      expect(shown).not_to include("Stats verified", "2.1K")
      expect(shown).to include("192", "From the show's RSS feed")
    end

    it "marks a show open to sponsors" do
      podcast.update!(open_to_sponsors: true)
      expect(texts(described_class.new(podcast))).to include("Open to sponsors")
    end
  end

  it "never shows Qloo taste data" do
    owner = create(:show, podcast: podcast)
    create(:report, show: owner, status: "done", audience: { "tags" => [ { "id" => "t1", "name" => "Cybersecurity fans" } ] })

    expect(texts(described_class.new(podcast.reload)).join(" ")).not_to include("Cybersecurity fans")
  end

  describe "an episode's card" do
    let(:episode) do
      create(:episode, podcast: podcast, title: "EP 152: The Stuxnet Story", published_at: Time.utc(2026, 10, 2),
                       duration_seconds: 3_150)
    end

    it "has the episode's title, the show and host under it, and its date and length" do
      shown = texts(described_class.new(podcast, episode: episode))

      expect(shown).to include("Episode", "EP 152: The Stuxnet Story", "Darknet Diaries, hosted by Jack Rhysider",
                               "Oct 2, 2026 · 52 min")
    end

    it "has a key of its own" do
      expect(described_class.new(podcast, episode: episode).cache_key).not_to eq(described_class.new(podcast).cache_key)
    end
  end

  describe "#draw" do
    it "draws a 1200x630 PNG with the stored artwork, fetching nothing" do
      image = described_class.new(Podcast.includes(ShareImages::StoredArtwork::PRELOAD).find(podcast.id)).draw
      png = Vips::Image.new_from_buffer(image.png, "")
      box = ShareImages::Layout::ARTWORK

      expect(image.complete).to be(true)
      expect([ png.width, png.height ]).to eq([ 1200, 630 ])
      # The fallback square is ink (#22132b); the stored cover is drawn over it.
      expect(png.getpoint(box[:x] + box[:size] / 2, box[:y] + box[:size] / 2).first(3).map(&:round)).not_to eq([ 34, 19, 43 ])
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "draws the mark when the show has no stored artwork, and calls that complete" do
      bare = create(:podcast, :indexable, title: "No Art Yet")
      image = described_class.new(bare).draw
      box = ShareImages::Layout::ARTWORK

      expect(image.complete).to be(true)
      expect(Vips::Image.new_from_buffer(image.png, "").getpoint(box[:x] + 8, box[:y] + box[:size] / 2).first(3).map(&:round))
        .to eq([ 34, 19, 43 ])
    end

    it "is incomplete while stored artwork can't be read, so it's drawn again soon" do
      podcast.artwork_image.file.blob.update_column(:byte_size, ShareImages::StoredArtwork::ORIGINAL_LIMIT + 1)
      image = described_class.new(Podcast.includes(ShareImages::StoredArtwork::PRELOAD).find(podcast.id)).draw

      expect(image.complete).to be(false)
    end
  end

  describe "#cache_key" do
    it "changes when the podcast, its numbers or its artwork change" do
      first = described_class.new(podcast).cache_key

      travel 1.minute
      podcast.update!(claimed_at: Time.current)
      claimed = described_class.new(podcast.reload).cache_key
      expect(claimed).not_to eq(first)

      verified("listeners_30d", 2_140)
      expect(described_class.new(podcast.reload).cache_key).not_to eq(claimed)
    end

    it "reads nothing beyond what the podcast page preloads" do
      podcast.update!(claimed_at: Time.current)
      verified("listeners_30d", 2_140)
      loaded = Podcast.for_page.strict_loading.find(podcast.id)

      queries = []
      callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.new(loaded).version }
      expect(queries).to be_empty
    end
  end
end
