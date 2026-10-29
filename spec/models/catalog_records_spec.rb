require "rails_helper"

# The catalog's smaller records: images, redirects, episodes, people, suppressions and removal requests.
RSpec.describe "Catalog records" do
  describe Image do
    it "is keyed by a unique sha256 and defines square webp variants made as soon as a file is attached" do
      image = create(:image)
      expect(build(:image, sha256: image.sha256)).not_to be_valid
      expect(build(:image, sha256: "not-a-digest")).not_to be_valid

      variants = described_class.attachment_reflections["file"].named_variants
      expect(variants.keys).to eq(%i[thumb card page large])
      expect(variants.transform_values { |variant| variant.transformations[:resize_to_fill] })
        .to eq(thumb: [ 160, 160 ], card: [ 320, 320 ], page: [ 640, 640 ], large: [ 1280, 1280 ])
      expect(variants.values.map(&:preprocessed)).to all(be(true))
      expect(variants.values.map { |variant| variant.transformations[:format] }).to all(eq(:webp))
    end

    it "makes its variants on the artwork queue" do
      expect { create(:image, :with_file) }.to have_enqueued_job(ActiveStorage::TransformJob).on_queue("artwork").exactly(4).times
      expect(ActiveStorage::AnalyzeJob.new.queue_name).to eq("artwork")
    end

    it "is visible until suppressed" do
      image = create(:image)
      expect(image).to be_visible
      image.update!(suppressed_at: Time.current)
      expect(described_class.visible).not_to include(image)
    end
  end

  describe PodcastRedirect do
    it "keeps each old slug once" do
      redirect = create(:podcast_redirect)
      expect(build(:podcast_redirect, from_slug: redirect.from_slug)).not_to be_valid
    end
  end

  describe Episode do
    it "slugs the title, set on insert only, with 6 hex of the guid's SHA256 when the podcast has it already" do
      podcast = create(:podcast)
      episode = create(:episode, podcast: podcast, title: "Pricing your first product", guid: "abc-123")
      expect(episode.slug).to eq("pricing-your-first-product")
      expect(episode.to_param).to eq(episode.slug)

      twin = create(:episode, podcast: podcast, title: "Pricing your first product", guid: "def-456")
      expect(twin.slug).to eq("pricing-your-first-product-#{Digest::SHA256.hexdigest('def-456').first(6)}")
      expect(create(:episode, title: "Pricing your first product").slug).to eq("pricing-your-first-product")

      episode.update!(title: "Renamed")
      expect(episode.reload.slug).to eq("pricing-your-first-product")
    end

    it "gives a batch readable slugs when told which are taken, and a guid suffix when it can't check" do
      taken = Set["intro"]
      expect(described_class.slug_for("Intro", "g1", taken: taken)).to eq("intro-#{Digest::SHA256.hexdigest('g1').first(6)}")
      expect(described_class.slug_for("New", "g2", taken: taken)).to eq("new-#{Digest::SHA256.hexdigest('g2').first(6)}")
      expect(described_class.slug_for("Part two", "g3", taken: taken)).to eq("part-two")
      expect(described_class.slug_for("!!!", "abc-123")).to start_with("episode-")
    end

    it "is unique by guid within its podcast, and keeps descriptions to 4,000 characters" do
      episode = create(:episode, description: "y" * 5000)
      expect(episode.description.length).to eq(4000)
      expect(build(:episode, podcast: episode.podcast, guid: episode.guid)).not_to be_valid
      expect(build(:episode, guid: episode.guid)).to be_valid
    end
  end

  describe PodcastPerson do
    it "keys names so spellings of one person match, once per role" do
      person = create(:podcast_person, name: "Dr. Elena Cruz")
      expect(person.name_key).to eq("drelenacruz")
      expect(build(:podcast_person, podcast: person.podcast, name: "dr elena cruz")).not_to be_valid
      expect(build(:podcast_person, podcast: person.podcast, name: "dr elena cruz", role: "guest")).to be_valid
      expect(build(:podcast_person, role: "producer")).not_to be_valid
    end
  end

  describe Suppression do
    it "suppresses a podcast by guid or by its feed URL's digest, and images by sha256" do
      create(:suppression, kind: "podcast", value: Suppression.feed_digest("https://Feeds.Example.com/x/"))
      create(:suppression, kind: "podcast", value: "guid-1")
      create(:suppression, kind: "image", value: "a" * 64)

      expect(described_class.podcast?(feed_url: "https://feeds.example.com/x")).to be(true)
      expect(described_class.podcast?(guid: "guid-1")).to be(true)
      expect(described_class.podcast?(guid: "guid-2", feed_url: "https://other.example.com/")).to be(false)
      expect(described_class.podcast?).to be(false)
      expect(described_class.image?("a" * 64)).to be(true)
      expect(build(:suppression, kind: "podcast", value: "guid-1")).not_to be_valid
      expect(build(:suppression, kind: "person")).not_to be_valid
    end
  end

  describe RemovalRequest do
    it "starts pending and checks the email" do
      request = create(:removal_request)
      expect(request).to be_pending
      expect(build(:removal_request, email: "nope")).not_to be_valid
      expect(build(:removal_request, status: "maybe")).not_to be_valid
    end
  end
end
