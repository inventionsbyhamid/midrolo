require "rails_helper"

RSpec.describe StatsHelper do
  let(:podcast) { create(:podcast, :claimed, title: "The Founder's Ledger") }

  # The text as read: each text node apart, the way the page's flex gaps set them.
  def text(html) = Nokogiri::HTML.fragment(html).xpath(".//text()").map(&:text).join(" ").squish

  describe "#trust_badge" do
    it "names the level, the source and the date", :aggregate_failures do
      travel_to Time.utc(2026, 10, 30) do
        expect(text(helper.trust_badge("verified", source: "Spotify for Creators", at: Time.utc(2026, 10, 29))))
          .to eq("Verified with Spotify for Creators · Oct 29")
        expect(text(helper.trust_badge("provided"))).to eq("Provided by the show")
        expect(text(helper.trust_badge("feed", at: Time.utc(2025, 3, 2)))).to eq("From the feed Mar 2, 2025")
        expect(helper.trust_badge("verified")).to include("badge-success")
      end
    end

    it "reads a reading's source and date, and says when a verified one has expired", :aggregate_failures do
      travel_to Time.utc(2026, 10, 30) do
        fresh = build(:stat_reading, trust: "verified", source: "apple", captured_at: Time.utc(2026, 10, 29))
        expect(text(helper.trust_badge(fresh))).to eq("Verified with Apple Podcasts Connect · Oct 29")

        stale = build(:stat_reading, trust: "verified", source: "spotify", captured_at: Time.utc(2026, 8, 1), expires_at: 1.day.ago)
        expect(text(helper.trust_badge(stale))).to eq("Last verified Aug 1 Spotify for Creators")
        expect(helper.trust_badge(stale)).not_to include("badge-success")

        provided = build(:stat_reading, trust: "provided", source: "provided", captured_at: Time.utc(2026, 10, 2), evidence: { "demo" => true })
        expect(text(helper.trust_badge(provided))).to eq("Provided by the show Demo Oct 2")
      end
    end
  end

  it "labels numbers with their platform and period, and plays per episode as plays", :aggregate_failures do
    expect(helper.stats_metric_label(build(:stat_reading, metric: "listeners_30d", source: "spotify"))).to eq("Spotify listeners, 30 days")
    expect(helper.stats_metric_label(build(:stat_reading, metric: "plays_30d", source: "apple"))).to eq("Apple plays, 30 days")
    expect(helper.stats_metric_label(build(:stat_reading, metric: "streams_all_time", source: "spotify"))).to eq("Spotify streams, all time")
    expect(helper.stats_metric_label(build(:stat_reading, metric: "followers", source: "apple"))).to eq("Apple followers")
    derived = build(:stat_reading, source: "platforms", trust: "verified", evidence: { "sources" => %w[apple spotify] })
    expect(helper.stats_metric_label(derived)).to eq("Apple and Spotify plays per episode, 30 days")
    expect(helper.stats_source_name(derived)).to eq("Apple Podcasts Connect and Spotify for Creators")
    expect(helper.stats_metric_label(build(:stat_reading, source: "provided"))).to eq("Downloads per episode")
  end

  it "shows bands when the owner asks for them" do
    expect([ 0, 499, 500, 2_400, 9_999, 10_000, 250_000 ].map { |value| helper.stats_band(value) })
      .to eq([ "0 to 500", "0 to 500", "500 to 1,000", "1,000 to 2,500", "5,000 to 10,000", "10,000+", "10,000+" ])
  end

  it "names audience keys in plain words" do
    expect(%w[0-17 18-22 60+ unknown].map { |key| helper.stats_age_label(key) }).to eq([ "Under 18", "18 to 22", "60 and over", "Unknown" ])
    expect(helper.stats_gender_label("non_binary")).to eq("Non binary")
    expect([ helper.stats_country_name("gb"), helper.stats_country_name("ZZ"), helper.stats_country_name("other") ])
      .to eq([ "United Kingdom", "ZZ", "Elsewhere" ])
  end

  describe "the podcast page's partials" do
    def render_partial(name) = text(helper.render(partial: name, locals: { podcast: podcast }))

    it "render nothing before a claim or a reading" do
      expect(render_partial("podcasts/numbers")).to eq("")
      expect(render_partial("stats/audience")).to eq("")
      expect(helper.stats_verified_pill(podcast)).to be_nil
    end

    it "show every number with its source and date, leading with all time when the month was quiet" do
      travel_to Time.utc(2026, 10, 30, 9) do
        connection = create(:stat_connection, podcast: podcast)
        Stats::Record.call(connection, spotify_result(metrics: { "streams" => 0, "audience_listeners" => 0 }, breakdowns: {}))
        podcast.record_provided_downloads!(1_500)
        strip = render_partial("podcasts/numbers")

        expect(strip).to include("Key numbers Stats verified")
        expect(strip).to include("1,500 Downloads per episode Provided by the show Oct 30")
        expect(strip).to include("Spotify Verified with Spotify for Creators · Oct 30")
        expect(strip).to include("48,000 Spotify streams, all time 12,500 Spotify listeners, all time 1,310 Spotify followers")
        expect(strip).not_to include("30 days")
        expect(render_partial("stats/audience")).to include("Not enough Spotify listens yet to show the audience.")
      end
    end

    it "show the 30-day numbers first when there are some, and the audience" do
      connection = create(:stat_connection, podcast: podcast)
      Stats::Record.call(connection, spotify_result)
      strip = render_partial("podcasts/numbers")
      expect(strip.index("Spotify streams, 30 days")).to be < strip.index("Spotify streams, all time")
      expect(strip).to include("2,140 Spotify listeners, 30 days")

      audience = render_partial("stats/audience")
      expect(audience).to include("Who listens", "Spotify listeners, last 30 days", "28 to 34", "34%", "Women", "United States", "61%")
    end

    it "show bands instead of numbers when the owner chose them" do
      show = create(:show, podcast: podcast, verified_at: Time.current)
      create(:media_kit, show: show, bands_only: true)
      podcast.record_provided_downloads!(2_400)
      expect(render_partial("podcasts/numbers")).to include("1,000 to 2,500 Downloads per episode").and include("ranges")
    end

    it "show an expired verified number as last verified, without the pill" do
      travel_to Time.utc(2026, 10, 30) do
        create(:stat_reading, podcast: podcast, source: "spotify", metric: "followers", trust: "verified", value: 70,
                              captured_at: Time.utc(2026, 1, 5), expires_at: 1.day.ago)
        expect(render_partial("podcasts/numbers")).to include("Last verified Jan 5").and include("70 Spotify followers")
        expect(helper.stats_verified_pill(podcast)).to be_nil
      end
    end
  end
end
