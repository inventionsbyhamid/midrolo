module Taste
  # Call discipline for live Qloo requests (R92). Every uncached request, a retry included, takes a slot first: at most
  # per_minute in the current UTC minute (QLOO_MAX_PER_MINUTE, default 30) and daily_limit in the current UTC day (the
  # admin's AppSettings qloo_daily_call_limit, default 100). The counts live in a shared cache (Solid Cache in
  # production) and move by atomic increments, so every process and thread sees the same totals.
  #
  # Over a cap, acquire! gives back what it took and raises CallCapReached before any HTTP request is made. A store
  # that can't count (increment returns nil) refuses too: the caps protect a hard daily allowance, so they fail closed.
  class CallGuard
    DEFAULT_PER_MINUTE = 30
    DEFAULT_DAILY_LIMIT = 100
    KEY_PREFIX = "taste:calls".freeze
    MINUTE_TTL = 2.minutes
    DAY_TTL = 2.days

    Usage = Data.define(:today, :daily_limit, :minute, :per_minute)
    Counter = Data.define(:key, :limit, :expires_in, :name)

    class << self
      def per_minute = whole_number(ENV["QLOO_MAX_PER_MINUTE"], DEFAULT_PER_MINUTE)

      def daily_limit = whole_number(AppSettings.get(:qloo_daily_call_limit), DEFAULT_DAILY_LIMIT)

      private

      # A whole number of 0 or more, else the default.
      def whole_number(value, default)
        number = Integer(value.to_s.strip, 10)
        number.negative? ? default : number
      rescue ArgumentError
        default
      end
    end

    def initialize(store: Rails.cache, clock: -> { Time.now.utc })
      @store = store
      @clock = clock
    end

    # Takes one slot from every counter, or raises CallCapReached having taken none.
    def acquire!
      taken = []
      counters(@clock.call).each do |counter|
        count = @store.increment(counter.key, 1, expires_in: counter.expires_in)
        refuse!(taken, "the call counter is unavailable") if count.nil?
        taken << counter
        refuse!(taken, "#{counter.name} of #{counter.limit} calls is used up") if count > counter.limit
      end
      nil
    end

    # The counts so far in this UTC day and minute, with their caps.
    def usage
      now = @clock.call
      Usage.new(today: count(day_key(now)), daily_limit: self.class.daily_limit,
                minute: count(minute_key(now)), per_minute: self.class.per_minute)
    end

    private

    def counters(now)
      [ Counter.new(day_key(now), self.class.daily_limit, DAY_TTL, "the daily limit"),
        Counter.new(minute_key(now), self.class.per_minute, MINUTE_TTL, "the limit a minute") ]
    end

    def refuse!(taken, reason)
      taken.each { |counter| @store.decrement(counter.key, 1, expires_in: counter.expires_in) }
      message = "Qloo call guard: #{reason}"
      Rails.logger.warn("[Qloo] #{message}")
      raise CallCapReached, message
    end

    def count(key) = @store.read(key).to_i

    def day_key(now) = "#{KEY_PREFIX}:day:#{now.utc.strftime('%Y-%m-%d')}"

    def minute_key(now) = "#{KEY_PREFIX}:minute:#{now.utc.strftime('%Y-%m-%dT%H:%M')}"
  end
end
