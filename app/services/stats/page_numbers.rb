module Stats
  # What a podcast's page shows of its stats (build spec section 11, Display), from one query: the per-episode figure,
  # each platform's verified numbers grouped under the service they came from, its audience breakdown, and whether the
  # page may say "Stats verified". A podcast that isn't claimed shows none of it (before a claim, only feed facts).
  #
  # The 30-day numbers show when they are above zero, the all-time totals always (so a quiet month leads with them),
  # each labelled with its period. A reading past its expiry still shows, as "Last verified", but no longer counts.
  # Spotify's listener-days sum is never stored, so its "listeners, 30 days" is the window's own count.
  class PageNumbers
    # The numbers each platform shows, in order, when present: the 30-day ones first (left out at zero), then the
    # all-time totals and followers.
    SHOWN = {
      "spotify" => %w[streams_30d listeners_30d streams_all_time listeners_all_time followers],
      "apple" => %w[plays_30d listeners_30d engaged_listeners_30d plays_all_time listeners_all_time followers]
    }.freeze

    # A platform's numbers: its readings to show, the one the badge dates them by, and whether they have expired.
    Group = Data.define(:provider, :readings, :latest, :expired) do
      def expired? = expired
    end

    attr_reader :podcast, :readings

    def initialize(podcast, readings: nil, now: Time.current)
      @podcast = podcast
      @now = now
      @readings = readings || load_readings
    end

    def any? = podcast.claimed? && (per_episode.present? || groups.any?)

    # Any fresh verified reading: the header's "Stats verified" pill.
    def verified? = podcast.claimed? && readings.any? { |reading| reading.trust_verified? && !reading.expired?(@now) }

    # The per-episode figure the rate card uses (Podcast#best_downloads_reading's order: fresh first, the most trusted
    # first, then the newest), else a verified one that has expired, which shows as "Last verified".
    def per_episode
      return @per_episode if defined?(@per_episode)

      candidates = readings.select { |reading| reading.metric == StatReading::DOWNLOADS_PER_EPISODE }
      fresh = candidates.reject { |reading| reading.expired?(@now) }
      @per_episode = fresh.min_by { |reading| [ -StatReading::TRUST_LEVELS.index(reading.trust).to_i, -reading.captured_at.to_f ] } ||
                     candidates.select(&:trust_verified?).max_by(&:captured_at)
    end

    # One Group per platform with numbers, Spotify first.
    def groups
      @groups ||= SHOWN.filter_map { |provider, metrics| group(provider, metrics) }
    end

    # True when the owner chose to show bands instead of exact numbers (media_kits.bands_only on the owner's kit).
    def bands?
      @bands = load_bands if @bands.nil?
      @bands
    end

    # The platform's audience reading (breakdown jsonb), fresh first, else the last one; nil when never fetched.
    def audience(provider)
      list = readings.select { |reading| reading.source == provider.to_s && reading.metric == "#{provider}_audience" }
      list.reject { |reading| reading.expired?(@now) }.max_by(&:captured_at) || list.max_by(&:captured_at)
    end

    private

    def group(provider, metrics)
      own = readings.select { |reading| reading.source == provider && reading.trust_verified? && metrics.include?(reading.metric) }
      fresh = own.reject { |reading| reading.expired?(@now) }
      pool = fresh.presence || own
      shown = metrics.filter_map do |metric|
        reading = pool.find { |candidate| candidate.metric == metric }
        reading if reading && (reading.value.positive? || !metric.end_with?("_30d"))
      end
      return nil if shown.empty?

      Group.new(provider: provider, readings: shown, latest: shown.max_by(&:captured_at), expired: fresh.empty?)
    end

    def load_bands
      return podcast.listing&.bands_only? || false if podcast.association(:listing).loaded?
      return false unless podcast.claimed?

      MediaKit.joins(:show).where(shows: { podcast_id: podcast.id }).where.not(shows: { verified_at: nil }).pick(:bands_only) || false
    end

    # The readings already preloaded (Podcast.for_page may), else one query that strict loading doesn't refuse.
    def load_readings
      if podcast.association(:stat_readings).loaded?
        podcast.stat_readings.to_a
      elsif podcast.claimed?
        StatReading.where(podcast_id: podcast.id).to_a
      else
        []
      end
    end
  end
end
