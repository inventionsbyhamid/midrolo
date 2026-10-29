require "rails_helper"

RSpec.describe Podcast::Catalog do
  before { freeze_time }

  describe ".search_catalog" do
    it "finds by title, author and description, best first, never removed shows" do
      exact = create(:podcast, title: "Ocean Hour", author: "Kai")
      by_author = create(:podcast, title: "Waves", author: "Ocean Hour Media")
      create(:podcast, title: "Ocean Hour Classic", status: "removed")
      create(:podcast, title: "Unrelated")

      expect(Podcast.search_catalog("ocean hour")).to eq([ exact, by_author ])
    end

    it "matches a title spelled slightly differently, and words in the description" do
      podcast = create(:podcast, title: "Darknet Diaries", description: "Stories from the dark side of the internet.")
      expect(Podcast.search_catalog("darknet diary")).to include(podcast)
      expect(Podcast.search_catalog("internet stories")).to include(podcast)
    end

    it "is empty for an empty query" do
      create(:podcast)
      expect(Podcast.search_catalog("  ")).to be_empty
    end
  end

  describe "#feed_status" do
    it "is active with an episode in the last 90 days, else dormant" do
      expect(build(:podcast, last_published_at: 89.days.ago).feed_status).to eq("active")
      expect(build(:podcast, last_published_at: 91.days.ago).feed_status).to eq("dormant")
      expect(build(:podcast, last_published_at: nil).feed_status).to eq("dormant")
    end
  end

  describe "#meets_index_rule?" do
    let(:podcast) { create(:podcast, :active, :with_artwork, description: "About things.") }

    it "needs an active or dormant show with 3 episodes, a description and stored artwork" do
      expect(podcast.meets_index_rule?).to be(true)
      expect(podcast.tap { |p| p.status = "dormant" }.meets_index_rule?).to be(true)
      %w[pending failed removed].each { |status| expect(podcast.tap { |p| p.status = status }.meets_index_rule?).to be(false) }
    end

    it "is false with fewer episodes, no description, no artwork or taken down artwork" do
      expect(podcast.tap { |p| p.episode_count = 2 }.meets_index_rule?).to be(false)
      podcast.reload
      expect(podcast.tap { |p| p.description = nil }.meets_index_rule?).to be(false)
      podcast.reload
      podcast.artwork_image.update!(suppressed_at: Time.current)
      expect(podcast.meets_index_rule?).to be(false)
      expect(build(:podcast, :active, description: "x").meets_index_rule?).to be(false)
    end
  end

  describe "#next_fetch_interval" do
    it "reads claimed shows hourly, then by how recent the last episode is" do
      expect(build(:podcast, claimed_at: 1.day.ago, last_published_at: 1.year.ago).next_fetch_interval).to eq(1.hour)
      expect(build(:podcast, last_published_at: 2.days.ago).next_fetch_interval).to eq(6.hours)
      expect(build(:podcast, last_published_at: 20.days.ago).next_fetch_interval).to eq(12.hours)
      expect(build(:podcast, last_published_at: 60.days.ago).next_fetch_interval).to eq(24.hours)
      expect(build(:podcast, last_published_at: 200.days.ago).next_fetch_interval).to eq(7.days)
      expect(build(:podcast, last_published_at: nil).next_fetch_interval).to eq(7.days)
    end

    it "doubles the wait for each failure in a row, up to 7 days" do
      podcast = build(:podcast, claimed_at: 1.day.ago)
      expect([ 1, 2, 3 ].map { |failures| podcast.tap { |p| p.fetch_failures = failures }.next_fetch_interval })
        .to eq([ 2.hours, 4.hours, 8.hours ])
      expect(podcast.tap { |p| p.fetch_failures = 50 }.next_fetch_interval).to eq(7.days)
    end
  end
end
