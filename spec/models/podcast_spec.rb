require "rails_helper"

RSpec.describe Podcast do
  describe "validations and enums" do
    it "needs a title, a feed URL and a known status and source" do
      expect(build(:podcast)).to be_valid
      expect(build(:podcast, title: "")).not_to be_valid
      expect(build(:podcast, feed_url: " ")).not_to be_valid
      expect(build(:podcast, status: "lost")).not_to be_valid
      expect(build(:podcast, source: "rumor")).not_to be_valid
      expect(described_class::STATUSES).to eq(%w[pending active dormant failed removed])
      expect(described_class::SOURCES).to eq(%w[qloo_seed search claim sample admin])
    end

    it "keeps one podcast per feed URL, however it is spelled" do
      create(:podcast, feed_url: "https://Feeds.Example.com/show/")
      expect(build(:podcast, feed_url: "https://feeds.example.com/show")).not_to be_valid
      expect { create(:podcast).update_columns(feed_url: "https://feeds.example.com/show") }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "keeps descriptions to 4,000 characters" do
      expect(create(:podcast, description: "x" * 5000).description.length).to eq(4000)
    end

    it "stores the owner email encrypted" do
      podcast = create(:podcast, owner_email: "owner@example.com")
      stored = described_class.connection.select_value("SELECT owner_email FROM podcasts WHERE id = #{podcast.id}")
      expect(stored).not_to include("owner@example.com")
      expect(podcast.reload.owner_email).to eq("owner@example.com")
    end
  end

  describe ".normalize_feed_url" do
    it "lowercases the scheme and host, trims, and drops trailing slashes, leaving the path and query alone" do
      expect(described_class.normalize_feed_url(" HTTPS://Feeds.Example.COM/Show/RSS/ ")).to eq("https://feeds.example.com/Show/RSS")
      expect(described_class.normalize_feed_url("https://x.example/feed?Key=A")).to eq("https://x.example/feed?Key=A")
      expect(described_class.normalize_feed_url("fake://fake-1")).to eq("fake://fake-1")
      expect(described_class.normalize_feed_url("  ")).to be_nil
    end
  end

  describe "slugs" do
    it "is the parameterized title plus 6 characters of the public id, and the URL's param" do
      podcast = create(:podcast, title: "The Founder's Ledger")
      expect(podcast.slug).to eq("the-founder-s-ledger-#{podcast.public_id.first(6)}")
      expect(podcast.to_param).to eq(podcast.slug)
      expect(podcast.to_key).to eq([ podcast.public_id ])
      expect(create(:podcast, title: "!!!").slug).to start_with("podcast-")
    end

    it "moves with the title, and the old slug still finds the podcast" do
      podcast = create(:podcast, title: "Old Name")
      old = podcast.slug
      podcast.update!(title: "New Name")

      expect(podcast.slug).to start_with("new-name-")
      expect(described_class.find_by_slug_or_redirect(old)).to eq(podcast)
      expect(described_class.find_by_slug_or_redirect(podcast.slug)).to eq(podcast)
      expect(described_class.find_by_slug_or_redirect("nothing-here")).to be_nil

      podcast.update!(title: "Old Name")
      expect(podcast.slug).to eq(old)
      expect(podcast.redirects.pluck(:from_slug)).to eq([ podcast.slug_before_last_save ])
    end

    it "keys the title for name matching" do
      expect(create(:podcast, title: "The Founder's Ledger").title_key).to eq("foundersledger")
    end
  end

  describe ".find_or_build_from_lookup" do
    let(:lookup) do
      { directory_id: "577105", itunes_id: "1296350485", feed_url: "https://Feeds.Example.com/darknet/",
        title: "Darknet Diaries", author: "Jack Rhysider", description: "Hacking stories.",
        artwork_url: "https://img.example.com/dd.jpg", categories: %w[Technology], episode_count: 160, language: "en" }
    end

    it "builds a podcast from a directory hit, with the source the caller gives" do
      podcast = described_class.find_or_build_from_lookup(lookup.merge(source: "claim"))

      expect(podcast).to be_new_record
      expect(podcast).to have_attributes(podcast_index_id: 577_105, apple_id: 1_296_350_485, source: "claim",
                                         feed_url: "https://feeds.example.com/darknet", title: "Darknet Diaries",
                                         categories: %w[Technology], episode_count: 160)
      expect(described_class.find_or_build_from_lookup(lookup).source).to eq("search")
    end

    it "finds an existing podcast by Podcast Index id, Apple id or feed URL, filling only what it lacks" do
      existing = create(:podcast, feed_url: "https://feeds.example.com/darknet", title: "Darknet Diaries (feed)",
                                  author: nil, categories: [])
      found = described_class.find_or_build_from_lookup(lookup)

      expect(found).to eq(existing)
      expect(found).to have_attributes(title: "Darknet Diaries (feed)", author: "Jack Rhysider",
                                       categories: %w[Technology], podcast_index_id: 577_105)
      found.save!
      expect(described_class.find_or_build_from_lookup(lookup.merge(feed_url: "https://moved.example.com/x"))).to eq(existing)
      expect(described_class.find_or_build_from_lookup(directory_id: nil, itunes_id: "1296350485", feed_url: nil)).to eq(existing)
    end

    it "takes the demo directory's ids as feed URLs" do
      podcast = described_class.find_or_create_from_lookup!(ShowLookup.call(directory_id: "fake-1").attributes)
      expect(podcast).to have_attributes(podcast_index_id: nil, apple_id: 1_000_000_001, directory_id: "fake-1",
                                         itunes_id: "1000000001")
      expect(described_class.for_directory_id("fake-1")).to eq(podcast)
      expect(described_class.for_directory_id("999")).to be_nil
    end

    it "saves through find_or_create_from_lookup!, returning the podcast a parallel save made first" do
      created = described_class.find_or_create_from_lookup!(lookup)
      expect(created).to be_persisted
      expect(described_class.find_or_create_from_lookup!(lookup)).to eq(created)

      # Both requests looked before either saved; the other one's insert wins the unique index.
      raced = create(:podcast, feed_url: "https://feeds.example.com/raced")
      loser = build(:podcast, feed_url: "https://feeds.example.com/raced")
      allow(loser).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)
      calls = 0
      allow(described_class).to receive(:find_or_build_from_lookup).and_wrap_original do |original, *args|
        (calls += 1) == 1 ? loser : original.call(*args)
      end
      expect(described_class.find_or_create_from_lookup!(feed_url: "https://feeds.example.com/raced")).to eq(raced)
    end
  end

  describe "#ingest_later" do
    it "enqueues the ingest at the asked priority" do
      podcast = create(:podcast)
      expect { podcast.ingest_later }.to have_enqueued_job(Catalog::IngestPodcastJob).with(podcast.id).at_priority(10)
      expect { podcast.ingest_later(priority: :high) }.to have_enqueued_job(Catalog::IngestPodcastJob).at_priority(0)
      expect { podcast.ingest_later(priority: :low) }.to have_enqueued_job(Catalog::IngestPodcastJob).at_priority(20)
      expect { podcast.ingest_later(priority: :urgent) }.to raise_error(KeyError)
    end
  end

  describe "#artwork_variant" do
    it "is nil until artwork is stored, then the named variant, and nil again once suppressed" do
      podcast = create(:podcast)
      expect(podcast.artwork_variant(:thumb)).to be_nil

      podcast.update!(artwork_image: create(:image, :with_file))
      variant = podcast.artwork_variant(:card)
      expect(variant.variation.transformations).to include(resize_to_fill: [ 320, 320 ], format: :webp)

      podcast.artwork_image.update!(suppressed_at: Time.current)
      expect(podcast.reload.artwork_variant(:card)).to be_nil
      expect { podcast.artwork_variant(:huge) }.to raise_error(ArgumentError)
    end
  end

  describe "ownership" do
    it "has an owner show, a listing and a claim once a show of it is verified" do
      podcast = create(:podcast)
      workspace = create(:show, podcast: podcast)
      expect([ podcast.owner_show, podcast.listing, podcast.claimed? ]).to eq([ nil, nil, false ])

      kit = create(:media_kit, show: workspace)
      workspace.verify!(via: "email")
      podcast.reload
      expect([ podcast.owner_show, podcast.listing, podcast.claimed? ]).to eq([ workspace, kit, true ])
      expect(described_class.claimed).to eq([ podcast ])
    end
  end

  describe "#best_downloads_reading and #refresh_listing!" do
    let(:podcast) { create(:podcast) }

    it "prefers verified, then provided, then the freshest, and ignores expired readings" do
      expect(podcast.best_downloads_reading).to be_nil

      create(:stat_reading, podcast: podcast, source: "feed", trust: "feed", value: 50, captured_at: 1.hour.ago)
      provided = create(:stat_reading, podcast: podcast, source: "show", trust: "provided", value: 900)
      expect(podcast.best_downloads_reading).to eq(provided)

      create(:stat_reading, podcast: podcast, source: "old", trust: "verified", value: 5000, expires_at: 1.day.ago)
      expect(podcast.best_downloads_reading).to eq(provided)

      verified = create(:stat_reading, podcast: podcast, source: "spotify", trust: "verified", value: 2100,
                                       captured_at: 2.days.ago)
      create(:stat_reading, podcast: podcast, metric: "followers", source: "apple", trust: "verified", value: 99_999)
      expect(podcast.best_downloads_reading).to eq(verified)
    end

    it "copies the best reading and the published listing into the directory's columns" do
      create(:stat_reading, podcast: podcast, trust: "verified", source: "spotify", value: 2100)
      podcast.refresh_listing!
      expect(podcast).to have_attributes(downloads_per_episode: 2100, downloads_trust: "verified",
                                         open_to_sponsors: false, min_price_cents: nil)

      show = create(:show, podcast: podcast)
      create(:media_kit, :published, show: show, open_to_sponsors: true, rate_card_overrides: { "midroll" => "300",
                                                                                                 "preroll" => "120" })
      podcast.refresh_listing!
      expect(podcast).to have_attributes(open_to_sponsors: true, min_price_cents: be_between(1, 12_000))
    end
  end

  describe "#link_qloo_entity!" do
    it "links an entity once, and never one another podcast holds" do
      podcast = create(:podcast)
      create(:podcast, qloo_entity_id: "TAKEN")

      expect(podcast.link_qloo_entity!("TAKEN")).to be(false)
      expect(podcast.link_qloo_entity!("Q1")).to be(true)
      expect(podcast.link_qloo_entity!("Q2")).to be(false)
      expect(podcast.reload.qloo_entity_id).to eq("Q1")
    end
  end

  describe "scopes" do
    it "selects indexable, active, claimed, open to sponsors and due podcasts" do
      indexable = create(:podcast, :indexable)
      due = create(:podcast, next_fetch_at: 1.minute.ago)
      create(:podcast, next_fetch_at: 1.minute.ago, status: "removed")
      create(:podcast, next_fetch_at: 1.minute.ago, leased_until: 5.minutes.from_now)
      create(:podcast, next_fetch_at: 1.hour.from_now)
      open = create(:podcast, open_to_sponsors: true)

      expect(described_class.indexable).to eq([ indexable ])
      expect(described_class.active).to eq([ indexable ])
      expect(described_class.open_to_sponsors).to eq([ open ])
      expect(described_class.due_for_fetch).to eq([ due ])
    end
  end

  it "searches titles, authors and descriptions through the stored tsvector" do
    match = create(:podcast, title: "Cold Case Cafe", description: "Unsolved mysteries retold over coffee.")
    create(:podcast, title: "Index Fund Mornings")

    expect(described_class.where("searchable @@ plainto_tsquery('english', ?)", "mystery")).to eq([ match ])
    expect(described_class.where("title % ?", "Cold Case Caffe")).to eq([ match ])
  end

  it "won't be destroyed while a user has a workspace for it" do
    podcast = create(:show).podcast
    expect { podcast.destroy }.to raise_error(ActiveRecord::DeleteRestrictionError)
  end
end
