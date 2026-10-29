require "rails_helper"

RSpec.describe PodcastDirectory do
  def titles(params = {}, category: nil) = described_class.new(params, category: category).podcasts.map(&:title)

  describe "params" do
    it "keeps what it knows and drops the rest" do
      directory = described_class.new({ q: "  darknet   diaries ", size: "500-1000", price: "250", language: "EN", open: "1",
                                      verified: "yes", sort: "nonsense", page: "3", evil: "1" })
      expect(directory).to have_attributes(query: "darknet diaries", size: "500-1000", price: 250, language: "en",
                                           sort: "relevance", page: 3)
      expect([ directory.open?, directory.verified?, directory.sponsored? ]).to eq([ true, false, false ])
      expect(described_class.new({ size: "1-2", price: "99", language: "english" }).to_params).to eq({})
    end

    it "caps the page and never sorts by relevance without a search" do
      expect(described_class.new({ page: "999" }).page).to eq(PodcastDirectory::MAX_PAGE)
      expect(described_class.new({ page: "-4" }).page).to eq(1)
      expect(described_class.new({ sort: "relevance" }).sort).to eq("newest")
      expect(described_class.new({ sort: "relevance" }).sort_options.keys).to eq(%w[newest downloads])
    end

    it "is plain only for the first page of an unfiltered listing" do
      expect(described_class.new.plain?).to be(true)
      expect(described_class.new({ q: "x" }).plain?).to be(false)
      expect(described_class.new({ open: "1" }).plain?).to be(false)
      expect(described_class.new({ page: "2" }).plain?).to be(false)
      expect(described_class.new({ sort: "downloads" }).plain?).to be(false)
      expect(described_class.new({}, category: "Technology").plain?).to be(true)
      expect(described_class.new({ category: "Technology" }).plain?).to be(false)
    end

    it "builds the params for links that change one thing" do
      directory = described_class.new({ q: "tech", open: "1", page: "2" })
      expect(directory.to_params(page: 3)).to eq(q: "tech", open: "1", page: 3)
      expect(directory.to_params(page: nil, open: nil)).to eq(q: "tech")
      expect(described_class.new({ size: "0-500" }, category: "Technology").to_params).to eq(size: "0-500")
    end
  end

  describe "#podcasts" do
    let!(:big) do
      create(:podcast, :active, :claimed, title: "Big Verified", categories: [ "Technology" ], language: "en",
                                          downloads_per_episode: 6_000, downloads_trust: "verified", open_to_sponsors: true,
                                          min_price_cents: 20_000, last_published_at: 5.days.ago)
    end
    let!(:small) do
      create(:podcast, :active, title: "Small Provided", categories: [ "Comedy" ], language: "es-mx", downloads_per_episode: 300,
                                downloads_trust: "provided", min_price_cents: 5_000, last_published_at: 1.day.ago)
    end
    let!(:quiet) { create(:podcast, status: "dormant", title: "Quiet Show", categories: [ "Technology" ], last_published_at: 1.year.ago) }

    before do
      create(:podcast, status: "pending", title: "Pending Show")
      create(:podcast, status: "failed", title: "Failed Show")
      create(:podcast, status: "removed", title: "Removed Show")
    end

    it "lists active and dormant podcasts, the most recent episode first" do
      expect(titles).to eq([ "Small Provided", "Big Verified", "Quiet Show" ])
    end

    it "filters by category, language, size, price and the toggles" do
      expect(titles({ category: "Technology" })).to eq([ "Big Verified", "Quiet Show" ])
      expect(titles({}, category: "Comedy")).to eq([ "Small Provided" ])
      expect(titles({ language: "es" })).to eq([ "Small Provided" ])
      expect(titles({ size: "5000-10000" })).to eq([ "Big Verified" ])
      expect(titles({ size: "0-500" })).to eq([ "Small Provided" ])
      expect(titles({ price: "100" })).to eq([ "Small Provided" ])
      expect(titles({ open: "1" })).to eq([ "Big Verified" ])
      expect(titles({ verified: "1" })).to eq([ "Big Verified" ])
      big.update!(claimed_at: nil) # numbers belong to a claim (code review L8)
      expect(titles({ verified: "1" })).to eq([])
      big.update!(claimed_at: 1.day.ago)
      create(:sponsor_mention, episode: create(:episode, podcast: quiet))
      expect(titles({ sponsored: "1" })).to eq([ "Quiet Show" ])
    end

    it "sorts by downloads, shows without numbers last" do
      expect(titles({ sort: "downloads" })).to eq([ "Big Verified", "Small Provided", "Quiet Show" ])
    end

    it "searches, best match first" do
      expect(titles({ q: "verified" })).to eq([ "Big Verified" ])
      expect(titles({ q: "show", sort: "newest" })).to eq([ "Quiet Show" ])
    end

    it "pages with one extra row to know there's a next page, and stops at the cap" do
      stub_const("PodcastDirectory::PER_PAGE", 2)
      first = described_class.new
      expect([ first.podcasts.size, first.next_page?, first.previous_page? ]).to eq([ 2, true, false ])
      second = described_class.new({ page: "2" })
      expect([ second.podcasts.map(&:title), second.next_page?, second.previous_page? ]).to eq([ [ "Quiet Show" ], false, true ])

      stub_const("PodcastDirectory::MAX_PAGE", 1)
      expect(described_class.new.next_page?).to be(false)
    end

    it "loads the cards' artwork up front and refuses lazy loads" do
      podcasts = described_class.new.podcasts
      expect(podcasts.first).to be_strict_loading
      expect { podcasts.each(&:artwork_image) }.not_to raise_error
    end
  end
end
