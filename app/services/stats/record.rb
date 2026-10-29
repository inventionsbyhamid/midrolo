module Stats
  # Saves a successful Stats::PlatformFetch result as the podcast's verified readings from that platform (build spec
  # section 11 and its live Spotify addendum): the 30-day counts (streams_30d, starts_30d, listeners_30d, plays_30d,
  # engaged_listeners_30d), the all-time totals (streams_all_time, starts_all_time, listeners_all_time) and followers,
  # each its own StatReading (trust verified, source the platform, expiring StatReading::TTL after capture), plus the
  # audience breakdown (age, gender, country) on a "<platform>_audience" reading. Then it refreshes plays per episode
  # and the podcast's listing columns. Returns the readings written.
  #
  # The breakdown comes from the result. When the 30 days had none, Stats::SyncJob passes audience: KEEP_LAST_AUDIENCE
  # and the last audience reading stays as it was, since the fetch over the last 12 months runs on its own, at most
  # weekly (Stats::AudienceJob, which saves its answer with Record.audience). An audience reading with an empty
  # breakdown means the platform answered with none to give, which the audience card says plainly. When the call
  # behind the breakdown failed this time (the helper lists its keys as unavailable), the last audience reading is
  # kept as it was too.
  class Record
    # Counts over the fetch's window; the helper names them bare ("streams"), or with _30d.
    WINDOW_COUNTS = %w[streams starts listeners plays engaged_listeners].freeze
    # The helper's keys that mean something else on a platform. Spotify's "listeners" sums daily listener counts (one
    # person on three days counts three times), so it isn't kept; its listeners over the window are
    # "audience_listeners", the count its breakdowns are built on (coordinator ruling, 2026-10-30).
    PLATFORM_KEYS = { "spotify" => { "listeners" => nil, "audience_listeners" => "listeners_30d" } }.freeze
    # The helper's count of the listeners a breakdown describes, per platform.
    AUDIENCE_COUNT = { "spotify" => "audience_listeners", "apple" => "listeners" }.freeze
    # Breakdowns kept on the audience reading: shares from 0 to 1 by key, or (country_rank) a list of country codes.
    SHARE_BREAKDOWNS = %w[age gender country].freeze
    RANK_BREAKDOWNS = %w[country_rank].freeze
    BREAKDOWN_KEY = /\A[A-Za-z0-9_+\-]{1,40}\z/
    BREAKDOWN_LIMIT = 30
    # audience: for "leave the audience reading as it is" (a fetch that wasn't made this time).
    KEEP_LAST_AUDIENCE = { "ok" => false, "error" => "not_asked" }.freeze

    def self.call(connection, result, audience: nil, now: Time.current) = new(connection, result, audience, now).call

    # Saves only the audience reading, from a fetch over a longer window (Stats::AudienceJob), when the platform
    # answered for the breakdown (an empty one included). Returns the reading, or nil when there was nothing to save.
    def self.audience(connection, fetch, now: Time.current) = new(connection, fetch, nil, now).save_audience

    # The reading's metric for one of the helper's metric keys on a platform, or nil for one Midrolo doesn't keep.
    def self.metric_for(provider, key)
      key = key.to_s
      renames = PLATFORM_KEYS.fetch(provider.to_s, {})
      return renames[key] if renames.key?(key)

      base = key.delete_suffix("_30d").delete_suffix("_all_time").delete_suffix("_total").delete_prefix("all_time_")
      return "followers" if key == "followers"
      return nil unless WINDOW_COUNTS.include?(base)
      return "#{base}_all_time" if key.end_with?("_all_time", "_total") || key.start_with?("all_time_")

      "#{base}_30d"
    end

    def initialize(connection, result, audience, now)
      @connection = connection
      @podcast = connection.podcast
      @result = result
      @audience = audience
      @now = now
    end

    def call
      rows = metric_rows
      return [] if rows.empty?

      rows << audience_row if audience_row

      StatReading.transaction do
        StatReading.upsert_all(rows, unique_by: %i[podcast_id metric source])
        podcast.refresh_plays_per_episode!(now)
        podcast.refresh_listing!
        podcast.touch
      end
      podcast.stat_readings.where(source: source, metric: rows.pluck(:metric)).to_a
    end

    def save_audience
      return unless result["ok"] && breakdown_answered?(result)

      row = audience_row_for(result)
      StatReading.transaction do
        StatReading.upsert_all([ row ], unique_by: %i[podcast_id metric source])
        podcast.touch
      end
      podcast.stat_readings.find_by(source: source, metric: row[:metric])
    end

    private

    attr_reader :connection, :podcast, :result, :audience, :now

    def source = connection.provider

    def period_days(fetch = result)
      days = fetch.dig("period", "days")
      days.is_a?(Integer) && days.positive? ? days : ::Stats::PlatformFetch::WINDOW_DAYS
    end

    def metric_rows
      result.fetch("metrics", {}).filter_map do |key, value|
        metric = self.class.metric_for(source, key)
        next unless metric && value.is_a?(Integer) && value >= 0

        row(metric, value, period_days: metric.end_with?("_30d") ? period_days : nil)
      end.uniq { |row| row[:metric] }
    end

    # Written whenever the platform answered for the breakdown, even with none, so the card can tell "not enough
    # listens yet" from "never fetched"; nil when it couldn't be read this time.
    def audience_row
      return @audience_row if defined?(@audience_row)

      fetch = audience_fetch
      @audience_row = fetch && audience_row_for(fetch)
    end

    def audience_row_for(fetch)
      count = fetch.dig("metrics", AUDIENCE_COUNT.fetch(source, "listeners"))
      row("#{source}_audience", count.is_a?(Integer) && count >= 0 ? count : 0, period_days: period_days(fetch),
                                breakdown: breakdowns(fetch), fetch: fetch)
    end

    def audience_fetch
      return result if breakdowns(result).any?
      return (result if breakdown_answered?(result)) if audience.nil?

      audience if audience["ok"] && breakdown_answered?(audience)
    end

    def breakdown_answered?(fetch) = (Array(fetch["unavailable"]) & SHARE_BREAKDOWNS).empty?

    # Only what the screen draws, cleaned: shares are floats from 0 to 1 under short keys, ranks are short codes.
    def breakdowns(fetch = result)
      raw = fetch.fetch("breakdowns", {})
      kept = {}
      SHARE_BREAKDOWNS.each do |name|
        shares = raw[name]
        next unless shares.is_a?(Hash)

        clean = shares.each_with_object({}) do |(key, share), out|
          out[key.to_s] = share.to_f.round(4) if key.to_s.match?(BREAKDOWN_KEY) && share.is_a?(Numeric) && share.between?(0, 1)
        end
        kept[name] = clean.sort_by { |_key, share| -share }.first(BREAKDOWN_LIMIT).to_h if clean.any?
      end
      RANK_BREAKDOWNS.each do |name|
        list = Array(raw[name]).map(&:to_s).grep(BREAKDOWN_KEY).first(BREAKDOWN_LIMIT)
        kept[name] = list if list.any?
      end
      kept
    end

    def row(metric, value, period_days:, breakdown: {}, fetch: result)
      { podcast_id: podcast.id, metric: metric, source: source, trust: "verified", value: value,
        period_days: period_days, captured_at: now, expires_at: now + StatReading::TTL, evidence: evidence(fetch),
        breakdown: breakdown }
    end

    # Where the number came from: the connection, the platform's show and the dates it covers.
    def evidence(fetch)
      {
        "connection_id" => connection.id, "show_id" => connection.external_id.to_s,
        "show_name" => fetch.dig("show", "name").to_s.first(200).presence,
        "period_start" => fetch.dig("period", "start").to_s.first(10).presence,
        "period_end" => fetch.dig("period", "end").to_s.first(10).presence
      }.compact
    end
  end
end
