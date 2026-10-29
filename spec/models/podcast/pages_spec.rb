require "rails_helper"

RSpec.describe Podcast::Pages do
  describe "categories and languages" do
    before do
      create(:podcast, :active, categories: [ "Technology", "News" ], language: "en-us")
      create(:podcast, :active, categories: [ "Technology" ], language: "EN")
      create(:podcast, status: "dormant", categories: [ "True Crime" ], language: "es")
      create(:podcast, status: "removed", categories: [ "Comedy" ], language: "fr")
      create(:podcast, status: "pending", categories: [ "Comedy" ])
    end

    it "counts the categories of listed podcasts, the biggest first" do
      expect(Podcast.category_counts).to eq([ [ "Technology", 2 ], [ "News", 1 ], [ "True Crime", 1 ] ])
    end

    it "finds a category by its slug, only when a listed podcast has it" do
      expect(Podcast.category_for_slug("true-crime")).to eq("True Crime")
      expect(Podcast.category_for_slug("comedy")).to be_nil
      expect(Podcast.category_slug("True Crime")).to eq("true-crime")
    end

    it "counts languages by their main code and filters on it" do
      expect(Podcast.language_counts).to eq([ [ "en", 2 ], [ "es", 1 ] ])
      expect(Podcast.in_language("en").count).to eq(2)
      expect(Podcast.in_language("es").count).to eq(1)
    end
  end

  describe ".for_page" do
    it "loads what the page reads, so strict loading never trips" do
      podcast = create(:podcast, :indexable, :with_artwork)
      create(:podcast_person, podcast: podcast)
      create(:stat_reading, podcast: podcast)
      kit = create(:media_kit, :published, show: create(:show, podcast: podcast))

      loaded = Podcast.for_page.strict_loading.find(podcast.id)
      expect { [ loaded.artwork_variant(:page), loaded.owner_show.media_kit, loaded.listing, loaded.people.to_a,
                 loaded.stat_readings.to_a, loaded.owner_show.podcast.title ] }.not_to raise_error
      expect(loaded.listing).to eq(kit)
    end
  end

  describe "#similar_podcasts" do
    let(:podcast) { create(:podcast, :active, categories: [ "Technology" ]) }

    it "puts shows sharing the most sponsors first, then listed shows in the same categories, never itself" do
      brands = create_list(:brand, 2)
      brands.each { |brand| create(:sponsor_mention, episode: create(:episode, podcast: podcast), brand: brand) }
      two = create(:podcast, :active, categories: [ "Comedy" ])
      one = create(:podcast, :active, categories: [ "Comedy" ])
      brands.each { |brand| create(:sponsor_mention, episode: create(:episode, podcast: two), brand: brand) }
      create(:sponsor_mention, episode: create(:episode, podcast: one), brand: brands.first)
      same_category = create(:podcast, :active, categories: [ "Technology", "News" ])
      create(:podcast, status: "removed", categories: [ "Technology" ])
      create(:podcast, :active, categories: [ "Health" ])

      expect(podcast.similar_podcasts).to eq([ two, one, same_category ])
    end

    it "is empty for a show with no sponsors and no categories" do
      expect(create(:podcast, :active, categories: []).similar_podcasts).to eq([])
    end
  end

  describe "#remove!" do
    it "takes the page down for good: status, suppressions, artwork and people's photos" do
      podcast = create(:podcast, :indexable, :with_artwork, podcast_guid: "guid-123", open_to_sponsors: true)
      photo = create(:image, :with_file)
      create(:podcast_person, podcast: podcast, image: photo)

      podcast.remove!

      expect(podcast.reload).to have_attributes(status: "removed", indexable: false, open_to_sponsors: false)
      expect(Suppression.podcast?(guid: "guid-123")).to be(true)
      expect(Suppression.podcast?(feed_url: podcast.feed_url)).to be(true)
      expect(Suppression.image?(podcast.artwork_image.sha256)).to be(true)
      expect(Suppression.image?(photo.sha256)).to be(true)
      expect(podcast.artwork_image.reload.visible?).to be(false)
      expect(photo.reload.visible?).to be(false)
      expect(podcast.artwork_variant(:page)).to be_nil
    end

    it "can run twice" do
      podcast = create(:podcast, :active)
      podcast.remove!
      expect { podcast.remove! }.not_to change(Suppression, :count)
    end
  end
end
