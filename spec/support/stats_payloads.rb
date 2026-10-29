# Hand-written results in the shape Stats::PlatformFetch returns (build spec section 11; never real platform data).
module StatsPayloads
  def spotify_result(show_name: "The Founder's Ledger", rss_url: nil, metrics: {}, breakdowns: nil, days: 30)
    last = Time.now.utc.to_date - 1
    { "ok" => true, "platform" => "spotify",
      "show" => { "id" => "4rOoJ6Egrf8K2IrywzwOMk", "name" => show_name, "rss_url" => rss_url }.compact,
      "period" => { "start" => (last - (days - 1)).iso8601, "end" => last.iso8601, "days" => days },
      "metrics" => { "streams" => 2_400, "starts" => 3_100, "listeners" => 9_000, "audience_listeners" => 2_140,
                     "streams_all_time" => 48_000, "starts_all_time" => 61_000, "listeners_all_time" => 12_500,
                     "followers" => 1_310 }.merge(metrics),
      "breakdowns" => breakdowns || {
        "age" => { "18-22" => 0.12, "23-27" => 0.31, "28-34" => 0.34, "35-44" => 0.18, "unknown" => 0.05 },
        "gender" => { "female" => 0.46, "male" => 0.5, "non_binary" => 0.01, "not_specified" => 0.03 },
        "country" => { "US" => 0.61, "GB" => 0.14, "CA" => 0.09, "other" => 0.16 }
      } }
  end

  def apple_result(show_name: "The Founder's Ledger", metrics: {})
    last = Time.now.utc.to_date - 1
    { "ok" => true, "platform" => "apple", "show" => { "id" => "1234567890", "name" => show_name },
      "period" => { "start" => (last - 29).iso8601, "end" => last.iso8601, "days" => 30 },
      "metrics" => { "plays" => 3_900, "listeners" => 1_200, "engaged_listeners" => 700, "followers" => 920 }.merge(metrics),
      "breakdowns" => { "country" => { "US" => 0.7, "AU" => 0.3 }, "country_rank" => %w[US AU] } }
  end

  def fetch_error(code, message = "plain words", retry_after: nil)
    Stats::PlatformFetch.failure(code, message, retry_after: retry_after)
  end

  # Lets every helper run through Stats::Throttle at once, for specs that run syncs back to back but aren't about the
  # throttle (Throttle.track still records each outcome).
  def allow_stats_runs
    allow(Stats::Throttle).to receive(:reserve) { Stats::Throttle::Slot.new(allowed: true, at: Time.current) }
  end
end

RSpec.configure { |config| config.include StatsPayloads }
