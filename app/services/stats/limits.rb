module Stats
  # How hard Midrolo may use its own Spotify and Apple accounts (Stats::Throttle), the same for each platform and
  # counted per platform: the seconds between helper runs plus a random extra of up to jitter seconds, and the runs
  # allowed in any hour and any 24 hours. AppSettings keys: a stored value wins, then ENV (the key upcased), then the
  # default. Also the form on /admin/service_sessions, kept as typed so a refused form shows what was entered.
  class Limits
    include ActiveModel::Model
    include ActiveModel::Attributes

    DEFAULTS = { stats_min_gap_seconds: 30, stats_gap_jitter_seconds: 15, stats_runs_per_hour: 40,
                 stats_runs_per_day: 300 }.freeze
    # What an admin may set. The gap never goes below 10 seconds: the point is to stay a light client.
    RANGES = { stats_min_gap_seconds: 10..3600, stats_gap_jitter_seconds: 0..3600, stats_runs_per_hour: 1..1000,
               stats_runs_per_day: 1..10_000 }.freeze
    LABELS = { stats_min_gap_seconds: "Seconds between runs", stats_gap_jitter_seconds: "Most random extra seconds",
               stats_runs_per_hour: "Runs an hour", stats_runs_per_day: "Runs a day" }.freeze
    WHOLE_NUMBER = /\A\d{1,6}\z/

    DEFAULTS.each_key { |key| attribute key, :string }

    validate :whole_numbers_in_range, :hour_fits_day

    # The values in force now; a stored value that isn't a whole number in range counts as unset.
    def self.current
      new(**DEFAULTS.to_h { |key, default| [ key, stored(key, default).to_s ] })
    end

    def self.stored(key, default)
      value = AppSettings.get(key, default: default).to_s.strip
      number = Integer(value, 10) if WHOLE_NUMBER.match?(value)
      number && RANGES.fetch(key).cover?(number) ? number : default
    end

    def self.human_attribute_name(attribute, options = {}) = LABELS.fetch(attribute.to_sym) { super }

    def min_gap = number(:stats_min_gap_seconds) || DEFAULTS[:stats_min_gap_seconds]
    def jitter = number(:stats_gap_jitter_seconds) || DEFAULTS[:stats_gap_jitter_seconds]
    def per_hour = number(:stats_runs_per_hour) || DEFAULTS[:stats_runs_per_hour]
    def per_day = number(:stats_runs_per_day) || DEFAULTS[:stats_runs_per_day]

    # What changed, as "key from x to y", for the admin log.
    def changed_settings = @changed_settings || []

    # Validates, then stores the values that changed. false (with errors) when one isn't allowed.
    def save
      @changed_settings = []
      return false unless valid?

      before = self.class.current
      Setting.transaction do
        DEFAULTS.each_key do |key|
          was, value = before.send(:number, key), number(key)
          next if was == value

          AppSettings.set(key, value)
          @changed_settings << "#{key} from #{was} to #{value}"
        end
      end
      true
    end

    private

    def number(key)
      value = public_send(key).to_s.strip
      Integer(value, 10) if WHOLE_NUMBER.match?(value)
    end

    def whole_numbers_in_range
      RANGES.each do |key, range|
        next if number(key) && range.cover?(number(key))

        errors.add(key, "must be a whole number from #{range.min} to #{range.max}.")
      end
    end

    def hour_fits_day
      return unless number(:stats_runs_per_hour) && number(:stats_runs_per_day)
      return if number(:stats_runs_per_hour) <= number(:stats_runs_per_day)

      errors.add(:stats_runs_per_hour, "can't be more than the runs a day.")
    end
  end
end
