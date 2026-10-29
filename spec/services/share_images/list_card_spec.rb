require "rails_helper"

RSpec.describe ShareImages::ListCard do
  def svg(card) = Nokogiri::XML(card.layout.svg) { |config| config.strict }

  def texts(card)
    svg(card).css("text").map { |node| node.css("tspan").any? ? node.css("tspan").map(&:text).join(" ") : node.text }
  end

  def tiles(card) = svg(card).css("[data-role='strip'] rect").size

  describe ".directory" do
    it "has the directory's title and a tile for each of the first shows with stored artwork, six at most" do
      shows = Array.new(8) { |i| create(:podcast, :indexable, :with_artwork, last_published_at: i.days.ago) }
      create(:podcast, :indexable, title: "No artwork", last_published_at: 1.hour.ago)
      card = described_class.directory

      expect(texts(card)).to include("Podcasts", "Find podcasts to sponsor",
                                     "Independent shows with their sponsors, rates and numbers, each with its source")
      expect(tiles(card)).to eq(6)
      expect(card.cache_key).to include(*shows.first(6).map { |show| show.cache_key_with_version })
      expect(card.cache_key).not_to include(shows.last.cache_key_with_version)
    end

    it "has no strip when no listed show has stored artwork" do
      create(:podcast, :indexable)
      card = described_class.directory

      expect(card).to be_empty
      expect(tiles(card)).to eq(0)
    end
  end

  describe ".category" do
    it "names the category and how many shows it has" do
      create(:podcast, :indexable, :with_artwork, categories: [ "Technology" ])
      card = described_class.category("Technology", count: 1_204)

      expect(texts(card)).to include("Category", "Technology podcasts to sponsor",
                                     "1,204 shows with their sponsors, rates and numbers, each with its source")
      expect(tiles(card)).to eq(1)
    end
  end

  describe ".brand" do
    let(:brand) { create(:brand, name: "Notion") }

    def sponsor(podcast, at)
      create(:sponsor_mention, brand: brand, episode: create(:episode, podcast: podcast, published_at: at))
    end

    it "says how many listed shows the brand sponsors, the latest first, and leaves out shows that aren't listed" do
      older = create(:podcast, :indexable, :with_artwork)
      newer = create(:podcast, :indexable, :with_artwork)
      gone = create(:podcast, :with_artwork, status: "removed")
      sponsor(older, 3.months.ago)
      sponsor(newer, 1.week.ago)
      sponsor(gone, 1.day.ago)

      podcasts = described_class.brand_podcasts(brand)
      card = described_class.brand(brand, podcasts: podcasts)

      expect(podcasts).to eq([ newer, older ])
      expect(texts(card)).to include("Sponsor", "Notion", "Sponsors 2 podcasts, found in their show notes")
      expect(card.alt).to eq("Podcasts Notion sponsors, on Midrolo")
    end
  end

  describe "#draw" do
    it "draws the tiles from storage, fetching nothing" do
      podcasts = Array.new(3) { create(:podcast, :indexable, :with_artwork) }
      image = described_class.new(label: "Category", title: "Technology podcasts to sponsor", subline: "3 shows",
                                  podcasts: podcasts, seed: "x").draw
      png = Vips::Image.new_from_buffer(image.png, "")
      x, y, size = ShareImages::Layout.strip_slots(3).first

      expect(image.complete).to be(true)
      expect([ png.width, png.height ]).to eq([ 1200, 630 ])
      expect(png.getpoint(x + size / 2, y + size / 2).first(3).map(&:round)).not_to eq([ 246, 242, 244 ]) # not the paper
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "draws the mark in a tile whose artwork can't be read, and calls the card incomplete" do
      podcast = create(:podcast, :indexable, :with_artwork)
      podcast.artwork_image.file.blob.update_column(:byte_size, ShareImages::StoredArtwork::ORIGINAL_LIMIT + 1)
      image = described_class.new(label: "Podcasts", title: "Find podcasts", subline: nil, podcasts: [ podcast ], seed: "x").draw
      x, y, = ShareImages::Layout.strip_slots(1).first

      expect(image.complete).to be(false)
      expect(Vips::Image.new_from_buffer(image.png, "").getpoint(x + 6, y + 40).first(3).map(&:round)).to eq([ 34, 19, 43 ])
    end
  end

  it "changes its key when a tiled show changes" do
    podcast = create(:podcast, :indexable, :with_artwork)
    first = described_class.directory.cache_key

    travel 1.minute
    podcast.update!(title: "A new name")
    expect(described_class.directory.cache_key).not_to eq(first)
  end
end
