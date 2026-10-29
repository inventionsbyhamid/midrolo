require "rails_helper"

RSpec.describe Stats::ExpireReadingsJob do
  it "drops an expired verified figure from the podcast's listing columns" do
    podcast = create(:podcast, :claimed)
    podcast.record_provided_downloads!(900)
    create(:stat_reading, podcast: podcast, source: "platforms", trust: "verified", value: 2_000, expires_at: 1.day.from_now)
    podcast.refresh_listing!
    expect(podcast.reload).to have_attributes(downloads_per_episode: 2_000, downloads_trust: "verified")

    travel 2.days do
      described_class.perform_now
      expect(podcast.reload).to have_attributes(downloads_per_episode: 900, downloads_trust: "provided")
      described_class.perform_now # again: no harm
    end
  end

  it "leaves podcasts whose readings didn't expire alone" do
    podcast = create(:podcast)
    create(:stat_reading, podcast: podcast, expires_at: 10.days.ago)
    expect { described_class.perform_now }.not_to(change { podcast.reload.updated_at })
  end
end
