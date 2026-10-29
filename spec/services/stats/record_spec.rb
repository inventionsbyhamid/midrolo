require "rails_helper"

RSpec.describe Stats::Record do
  let(:podcast) { create(:podcast, title: "The Founder's Ledger") }
  let(:spotify) { create(:stat_connection, podcast: podcast, provider: "spotify", external_id: "4rOoJ6Egrf8K2IrywzwOMk") }
  let(:apple) { create(:stat_connection, podcast: podcast, provider: "apple", external_id: "1234567890") }
  let(:now) { Time.current.change(usec: 0) }

  def readings(source) = podcast.stat_readings.where(source: source).index_by(&:metric)

  it "names the helper's keys per platform", :aggregate_failures do
    expect(described_class.metric_for("spotify", "streams")).to eq("streams_30d")
    expect(described_class.metric_for("spotify", "audience_listeners")).to eq("listeners_30d")
    expect(described_class.metric_for("spotify", "listeners")).to be_nil # listener days, never kept
    expect(described_class.metric_for("spotify", "streams_all_time")).to eq("streams_all_time")
    expect(described_class.metric_for("spotify", "followers")).to eq("followers")
    expect(described_class.metric_for("apple", "listeners")).to eq("listeners_30d")
    expect(described_class.metric_for("apple", "engaged_listeners")).to eq("engaged_listeners_30d")
    expect(described_class.metric_for("apple", "plays_total")).to eq("plays_all_time")
    expect(described_class.metric_for("apple", "mystery")).to be_nil
  end

  it "saves Spotify's 30-day and all-time numbers and its audience, verified, expiring in 45 days" do
    described_class.call(spotify, spotify_result, now: now)
    saved = readings("spotify")

    expect(saved.transform_values(&:value)).to eq(
      "streams_30d" => 2_400, "starts_30d" => 3_100, "listeners_30d" => 2_140, "streams_all_time" => 48_000,
      "starts_all_time" => 61_000, "listeners_all_time" => 12_500, "followers" => 1_310, "spotify_audience" => 2_140
    )
    expect(saved["streams_30d"]).to have_attributes(trust: "verified", period_days: 30, captured_at: now, expires_at: now + 45.days)
    expect(saved["streams_all_time"].period_days).to be_nil
    expect(saved["streams_30d"].evidence).to include("show_id" => "4rOoJ6Egrf8K2IrywzwOMk", "show_name" => "The Founder's Ledger",
                                                     "connection_id" => spotify.id)
    expect(saved["spotify_audience"].breakdown).to include("gender" => include("female" => 0.46),
                                                           "country" => include("US" => 0.61, "other" => 0.16))
  end

  it "updates the same rows on the next sync" do
    described_class.call(spotify, spotify_result, now: now - 1.day)
    described_class.call(spotify, spotify_result(metrics: { "followers" => 1_400 }), now: now)
    expect(podcast.stat_readings.where(source: "spotify", metric: "followers").sole).to have_attributes(value: 1_400, captured_at: now)
  end

  it "cleans the breakdown: no odd keys, no shares outside 0 to 1, no other lists" do
    result = spotify_result(breakdowns: { "age" => { "18-22" => 0.5, "<script>" => 0.2, "60+" => 1.5, "35-44" => "0.3" },
                                          "secret" => { "a" => 1 }, "country_rank" => [ "US", "x y" ] })
    described_class.call(spotify, result, now: now)
    expect(readings("spotify")["spotify_audience"].breakdown).to eq("age" => { "18-22" => 0.5 }, "country_rank" => [ "US" ])
  end

  it "keeps the last audience when the breakdown couldn't be read this time" do
    described_class.call(spotify, spotify_result, now: now - 1.day)
    failed = spotify_result(breakdowns: {}).merge("unavailable" => %w[audience_listeners age gender country])
    described_class.call(spotify, failed, now: now)
    expect(readings("spotify")["spotify_audience"]).to have_attributes(captured_at: now - 1.day, breakdown: include("age"))

    described_class.call(spotify, spotify_result(breakdowns: {}), audience: fetch_error("failed"), now: now)
    expect(readings("spotify")["spotify_audience"].captured_at).to eq(now - 1.day)

    described_class.call(spotify, spotify_result(breakdowns: {}), audience: spotify_result(breakdowns: {}, days: 365), now: now)
    expect(readings("spotify")["spotify_audience"]).to have_attributes(captured_at: now, breakdown: {}, period_days: 365)
  end

  it "saves Apple's numbers and its plays by country" do
    described_class.call(apple, apple_result, now: now)
    saved = readings("apple")
    expect(saved.transform_values(&:value)).to include("plays_30d" => 3_900, "listeners_30d" => 1_200,
                                                       "engaged_listeners_30d" => 700, "followers" => 920,
                                                       "apple_audience" => 1_200)
    expect(saved["apple_audience"].breakdown).to eq("country" => { "US" => 0.7, "AU" => 0.3 }, "country_rank" => %w[US AU])
  end

  it "derives plays per episode from both platforms over the episodes in the window" do
    podcast.update!(claimed_at: 1.day.ago) # the listing columns carry numbers for a claimed podcast only
    create(:episode, podcast: podcast, published_at: 2.days.ago)
    create(:episode, podcast: podcast, published_at: 20.days.ago)
    create(:episode, podcast: podcast, published_at: 60.days.ago)
    described_class.call(spotify, spotify_result, now: now)
    described_class.call(apple, apple_result, now: now)

    reading = podcast.stat_readings.find_by(metric: "downloads_per_episode", source: "platforms")
    expect(reading).to have_attributes(value: 3_150, trust: "verified", period_days: 30) # (2,400 + 3,900) / 2
    expect(reading.evidence).to include("sources" => %w[spotify apple], "plays" => 6_300, "episodes" => 2)
    expect(podcast.reload).to have_attributes(downloads_per_episode: 3_150, downloads_trust: "verified")
  end
end
