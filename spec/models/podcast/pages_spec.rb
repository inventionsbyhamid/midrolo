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
    it "takes the page down for good on an admin's approval: status, suppressions, artwork and people's photos" do
      podcast = create(:podcast, :indexable, :with_artwork, podcast_guid: "guid-123", open_to_sponsors: true)
      photo = create(:image, :with_file)
      create(:podcast_person, podcast: podcast, image: photo)

      podcast.remove!(by: :admin)

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
      podcast.remove!(by: :admin)
      expect { podcast.remove!(by: :admin) }.not_to change(Suppression, :count)
      expect { podcast.remove! }.not_to change(Suppression, :count)
    end

    # Code review H2: an owner proved control of their feed only. A feed can declare another show's podcast:guid or
    # use its artwork (one Image per sha256 is shared), so the owner's instant removal must not take those down.
    describe "by its owner" do
      let(:victim) { create(:podcast, :indexable, :with_artwork, title: "Real Show", description: "Real.", podcast_index_id: 9) }
      let(:decoy) do
        create(:podcast, :indexable, title: "Decoy", podcast_guid: "real-show-guid", artwork_image: victim.artwork_image)
      end

      it "suppresses only its own feed, never the guid or the shared artwork, and leaves other shows alone" do
        decoy.remove!(by: :owner)

        expect(decoy.reload).to have_attributes(status: "removed", indexable: false, artwork_image_id: nil)
        expect(Suppression.podcast?(feed_url: decoy.feed_url)).to be(true)
        expect(Suppression.podcast?(guid: "real-show-guid")).to be(false)
        expect(Suppression.image?(victim.artwork_image.sha256)).to be(false)
        expect(Suppression.count).to eq(1)

        victim.reload
        expect(victim.artwork_stored?).to be(true)
        expect(victim.artwork_variant(:page)).to be_present
        expect(victim.meets_index_rule?).to be(true)
      end

      it "deletes its own pictures that nothing else uses" do
        podcast = create(:podcast, :indexable, :with_artwork)
        photo = create(:image, :with_file)
        create(:podcast_person, podcast: podcast, image: photo)
        artwork = podcast.artwork_image

        podcast.remove!

        expect(Image.where(id: [ artwork.id, photo.id ])).to be_empty
        expect(podcast.people.pluck(:image_id)).to eq([ nil ])
        expect(Suppression.image.count).to eq(0)
      end

      it "doesn't stop a show that later declares the same guid from being read" do
        decoy.remove!(by: :owner)
        expect(Suppression.podcast?(guid: "real-show-guid", feed_url: "https://real.example.com/feed.xml")).to be(false)
      end
    end

    it "knows only owners and admins" do
      expect { create(:podcast).remove!(by: :visitor) }.to raise_error(ArgumentError)
    end
  end
end
