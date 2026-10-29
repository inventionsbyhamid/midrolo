# Podcast: verified stats (build spec section 11). Readings are written by Stats::SyncJob (verified, from Spotify for
# Creators and Apple Podcasts Connect) and by the owner (provided by the show). This concern derives the per-episode
# figure the rate card and the directory use, and keeps the denormalized listing columns (refresh_listing!) current.
#
# Lane L5 adds its methods here, and only here (build spec section 10), so lanes don't edit the same model file.
module Podcast::Stats
  extend ActiveSupport::Concern

  # The reading's source for plays per episode derived from the platforms' own counts.
  PLAYS_SOURCE = "platforms".freeze
  # The source of numbers the owner typed.
  PROVIDED_SOURCE = "provided".freeze
  # Which 30-day count each platform adds to plays per episode: Spotify streams (plays of 60 seconds or more) and
  # Apple plays.
  PLAY_METRICS = { "spotify" => "streams_30d", "apple" => "plays_30d" }.freeze

  # True when the page may say "Stats verified": the podcast is claimed and has a verified reading that hasn't expired.
  def stats_verified?(now = Time.current)
    claimed? && stat_readings.unexpired(now).trust_verified.exists?
  end

  # Plays per episode, verified (section 11): the platforms' 30-day plays (Spotify streams plus Apple plays, from fresh
  # verified readings) over the episodes published in that window. It is stored as the downloads_per_episode reading
  # from PLAYS_SOURCE, expiring with the earliest reading it was made from, and labelled "plays", never "downloads".
  # With no fresh plays an old figure is left to expire (and then reads "Last verified"); with fresh plays of zero, or
  # no episode in the window, there is no such figure and an old one goes.
  def refresh_plays_per_episode!(now = Time.current)
    inputs = stat_readings.unexpired(now).trust_verified.where(source: PLAY_METRICS.keys, metric: PLAY_METRICS.values)
                          .select { |reading| PLAY_METRICS[reading.source] == reading.metric }
    existing = stat_readings.find_by(metric: StatReading::DOWNLOADS_PER_EPISODE, source: PLAYS_SOURCE)
    return existing if inputs.empty?

    window_end = inputs.map { |reading| stats_period_end(reading) }.max
    plays = inputs.sum(&:value)
    episodes_in_window = stats_episodes_between(window_end - (::Stats::PlatformFetch::WINDOW_DAYS - 1), window_end)
    if plays.zero? || episodes_in_window.zero?
      existing&.destroy!
      return nil
    end

    reading = existing || stat_readings.new(metric: StatReading::DOWNLOADS_PER_EPISODE, source: PLAYS_SOURCE)
    reading.update!(value: (plays.to_f / episodes_in_window).round, trust: "verified",
                    period_days: ::Stats::PlatformFetch::WINDOW_DAYS, captured_at: inputs.map(&:captured_at).max,
                    expires_at: inputs.map(&:expires_at).compact.min,
                    evidence: { "sources" => inputs.map(&:source).sort_by { |source| PLAY_METRICS.keys.index(source) },
                                "plays" => plays, "episodes" => episodes_in_window,
                                "period_start" => (window_end - (::Stats::PlatformFetch::WINDOW_DAYS - 1)).iso8601,
                                "period_end" => window_end.iso8601 })
    reading
  end

  # The owner's own downloads per episode ("provided by the show"; section 10: typed downloads become a provided
  # reading only for the owner show). nil removes it. The date shown with it moves only when the number does.
  # demo: marks the demo show's numbers (lane L4's demo:setup).
  def record_provided_downloads!(value, demo: false, now: Time.current)
    reading = stat_readings.find_or_initialize_by(metric: StatReading::DOWNLOADS_PER_EPISODE, source: PROVIDED_SOURCE)
    if value.nil?
      reading.destroy! if reading.persisted?
    else
      reading.captured_at = now if reading.new_record? || reading.value != value.to_i
      reading.update!(value: value.to_i, trust: "provided", period_days: nil, expires_at: nil,
                      evidence: demo ? { "demo" => true } : {})
    end
    refresh_listing!
    touch
  end

  # Takes a platform's numbers off the podcast (the owner disconnected it): its readings, and the plays per episode
  # made from them.
  def remove_stat_source!(source)
    stat_readings.where(source: [ source.to_s, PLAYS_SOURCE ]).delete_all
    refresh_plays_per_episode!
    refresh_listing!
    touch
  end

  private

  # The last day a platform reading counts (its period's end, else the day before it was captured).
  def stats_period_end(reading)
    Date.iso8601(reading.evidence["period_end"].to_s)
  rescue Date::Error
    reading.captured_at.utc.to_date - 1
  end

  def stats_episodes_between(first_day, last_day)
    episodes.where(published_at: first_day.to_time(:utc)..last_day.to_time(:utc).end_of_day).count
  end
end
