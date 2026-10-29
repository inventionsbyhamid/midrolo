require "rails_helper"

RSpec.describe Podcast::Stats do
  let(:podcast) { create(:podcast, :claimed) }

  def verified(metric, value, source:, expires_at: 40.days.from_now, period_end: Time.now.utc.to_date - 1)
    create(:stat_reading, podcast: podcast, metric: metric, value: value, source: source, trust: "verified",
                          expires_at: expires_at, evidence: { "period_end" => period_end.iso8601 })
  end

  describe "#refresh_plays_per_episode!" do
    it "has no figure without an episode in the window, or with no plays" do
      verified("streams_30d", 900, source: "spotify")
      expect(podcast.refresh_plays_per_episode!).to be_nil

      create(:episode, podcast: podcast, published_at: 1.week.ago)
      podcast.stat_readings.update_all(value: 0)
      expect(podcast.refresh_plays_per_episode!).to be_nil
      expect(podcast.stat_readings.where(source: "platforms")).to be_empty
    end

    it "expires with the earliest reading it was made from, and is left to expire once they have" do
      create(:episode, podcast: podcast, published_at: 1.week.ago)
      verified("streams_30d", 900, source: "spotify", expires_at: 10.days.from_now)
      verified("plays_30d", 100, source: "apple", expires_at: 30.days.from_now)
      reading = podcast.refresh_plays_per_episode!
      expect(reading).to have_attributes(value: 1_000, expires_at: be_within(1.second).of(10.days.from_now))

      travel 11.days do
        podcast.stat_readings.where(source: "apple").delete_all
        expect(podcast.refresh_plays_per_episode!).to eq(reading) # nothing fresh: kept, and reads "Last verified"
      end
    end
  end

  describe "#record_provided_downloads!" do
    it "saves the owner's number as provided, keeps its date while it doesn't change, and removes it on nil" do
      travel_to(Time.utc(2026, 10, 1)) { podcast.record_provided_downloads!(1_500) }
      reading = podcast.stat_readings.find_by!(source: "provided")
      expect(reading).to have_attributes(value: 1_500, trust: "provided", expires_at: nil, evidence: {})
      expect(podcast.reload).to have_attributes(downloads_per_episode: 1_500, downloads_trust: "provided")

      podcast.record_provided_downloads!(1_500)
      expect(reading.reload.captured_at).to eq(Time.utc(2026, 10, 1))
      podcast.record_provided_downloads!(1_800, demo: true)
      expect(reading.reload).to have_attributes(value: 1_800, evidence: { "demo" => true })

      podcast.record_provided_downloads!(nil)
      expect(podcast.stat_readings.where(source: "provided")).to be_empty
      expect(podcast.reload.downloads_per_episode).to be_nil
    end

    it "loses to a fresh verified figure on the listing" do
      podcast.record_provided_downloads!(5_000)
      create(:stat_reading, podcast: podcast, source: "platforms", trust: "verified", value: 800)
      podcast.refresh_listing!
      expect(podcast.reload).to have_attributes(downloads_per_episode: 800, downloads_trust: "verified")
    end
  end

  it "#remove_stat_source! takes a platform's readings and the plays per episode made from them" do
    create(:episode, podcast: podcast, published_at: 1.week.ago)
    verified("streams_30d", 900, source: "spotify")
    verified("plays_30d", 100, source: "apple")
    podcast.refresh_plays_per_episode!
    podcast.remove_stat_source!("spotify")

    expect(podcast.stat_readings.pluck(:source).uniq).to contain_exactly("apple", "platforms")
    expect(podcast.stat_readings.find_by(source: "platforms").value).to eq(100)
  end

  it "#stats_verified? needs the claim and a fresh verified reading" do
    verified("followers", 10, source: "spotify", expires_at: 1.day.ago)
    expect(podcast.stats_verified?).to be(false)
    verified("streams_30d", 10, source: "spotify")
    expect(podcast.stats_verified?).to be(true)
    podcast.update!(claimed_at: nil)
    expect(podcast.stats_verified?).to be(false)
  end
end
