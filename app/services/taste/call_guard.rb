module Taste
  # Call discipline for live Qloo requests (R92). Every uncached request, a retry included, takes a slot first: at most
  # per_minute in the current UTC minute (QLOO_MAX_PER_MINUTE, default 30) and daily_limit in the current UTC day (the
  # admin's AppSettings qloo_daily_call_limit, default 100). The counts live in a shared cache (Solid Cache in
  # production) and move by atomic increments, so every process and thread sees the same totals.
  #
  # Free and promo users get a share of the day (R95, R108): a run inside CallGuard.lane(:capped) (Research::Run, for a
  # user who is neither a judge nor a paying subscriber) also counts against free_limit, AppSettings qloo_free_share
  # (default 0.4) of the daily limit, so they can't starve judges, paying users and sample generation, which use the
  # rest of the day.
  #
  # Over a cap, acquire! gives back what it took and raises CallCapReached (MinuteCapReached for the minute,
  # FreeShareSpent for the share) before any HTTP request is made. Inside CallGuard.waiting (ReportJob: background jobs
  # only, never a web request) a minute refusal first waits for the next UTC minute and tries again, at most
  # MAX_MINUTE_WAITS times a call (R109): a full report makes about 30 calls and would trip the minute cap by itself.
  # The daily limit and the share refuse at once. A store that can't count (increment returns nil) refuses too: the caps
  # protect a hard daily allowance, so they fail closed.
  #
  # One research run has a hard ceiling too (R130): inside CallGuard.run_ceiling (Research::StepLogger sets it around
  # each step), acquire! raises RunBudgetSpent, taking no slot, once the run's ceiling says it is reached.
  class CallGuard
    DEFAULT_PER_MINUTE = 30
    DEFAULT_DAILY_LIMIT = 100
    DEFAULT_FREE_SHARE = BigDecimal("0.4")
    LANES = [ nil, :capped ].freeze
    LANE_KEY = :taste_call_guard_lane
    WAIT_KEY = :taste_call_guard_wait
    RUN_KEY = :taste_call_guard_run_ceiling
    MAX_MINUTE_WAITS = 2
    # Past the minute boundary, so the next attempt lands in the new minute.
    MINUTE_MARGIN = 0.5
    KEY_PREFIX = "taste:calls".freeze
    MINUTE_TTL = 2.minutes
    DAY_TTL = 2.days

    Usage = Data.define(:today, :daily_limit, :minute, :per_minute, :free_today, :free_limit)
    Counter = Data.define(:key, :limit, :expires_in, :name, :error)

    class << self
      def per_minute = whole_number(ENV["QLOO_MAX_PER_MINUTE"], DEFAULT_PER_MINUTE)

      def daily_limit = whole_number(AppSettings.get(:qloo_daily_call_limit), DEFAULT_DAILY_LIMIT)

      # The free and promo users' share of the daily limit, from 0 to 1; the default when unset or out of range.
      def free_share
        share = BigDecimal(AppSettings.get(:qloo_free_share).to_s.strip)
        share.between?(0, 1) ? share : DEFAULT_FREE_SHARE
      rescue ArgumentError
        DEFAULT_FREE_SHARE
      end

      def free_limit = (daily_limit * free_share).floor

      # Runs the block in a lane (:capped, or nil for the shared one) on this thread or fiber, then restores the last.
      def lane(name)
        raise ArgumentError, "unknown call lane: #{name.inspect}" unless LANES.include?(name)

        previous = ActiveSupport::IsolatedExecutionState[LANE_KEY]
        ActiveSupport::IsolatedExecutionState[LANE_KEY] = name
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[LANE_KEY] = previous if LANES.include?(name)
      end

      def current_lane = ActiveSupport::IsolatedExecutionState[LANE_KEY]

      # Runs the block with minute refusals waiting for the next minute (R109), then restores the last setting.
      def waiting
        previous = ActiveSupport::IsolatedExecutionState[WAIT_KEY]
        ActiveSupport::IsolatedExecutionState[WAIT_KEY] = true
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[WAIT_KEY] = previous
      end

      def waiting? = ActiveSupport::IsolatedExecutionState[WAIT_KEY] == true

      # Runs the block under one run's hard ceiling (R130): reached answers whether the run may make no more live
      # calls. Restores the last ceiling after.
      def run_ceiling(reached)
        previous = ActiveSupport::IsolatedExecutionState[RUN_KEY]
        ActiveSupport::IsolatedExecutionState[RUN_KEY] = reached
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[RUN_KEY] = previous
      end

      def run_ceiling_reached? = ActiveSupport::IsolatedExecutionState[RUN_KEY]&.call == true

      private

      # A whole number of 0 or more, else the default.
      def whole_number(value, default)
        number = Integer(value.to_s.strip, 10)
        number.negative? ? default : number
      rescue ArgumentError
        default
      end
    end

    def initialize(store: Rails.cache, clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) })
      @store = store
      @clock = clock
      @sleeper = sleeper
    end

    # Takes one slot from every counter, or raises CallCapReached having taken none. Inside CallGuard.waiting, a full
    # minute is waited out first, at most MAX_MINUTE_WAITS times. A run past its hard ceiling gets RunBudgetSpent first.
    def acquire!
      refuse_past_run_ceiling!
      waits = 0
      begin
        take_slot!
      rescue MinuteCapReached
        raise unless self.class.waiting? && waits < MAX_MINUTE_WAITS

        waits += 1
        wait_for_next_minute
        retry
      end
    end

    # Whether a capped run would be refused now: its share, or the whole day, is used up (R108: the run form asks first).
    def capped_spent?
      now = usage
      now.free_today >= now.free_limit || now.today >= now.daily_limit
    end

    # The counts so far in this UTC day and minute, and the capped lane's today, with their caps.
    def usage
      now = @clock.call
      Usage.new(today: count(day_key(now)), daily_limit: self.class.daily_limit,
                minute: count(minute_key(now)), per_minute: self.class.per_minute,
                free_today: count(free_key(now)), free_limit: self.class.free_limit)
    end

    private

    def refuse_past_run_ceiling!
      return unless self.class.run_ceiling_reached?

      message = "Qloo call guard: this run's hard ceiling of calls is reached"
      Rails.logger.warn("[Qloo] #{message}")
      raise RunBudgetSpent, message
    end

    def take_slot!
      taken = []
      counters(@clock.call).each do |counter|
        count = @store.increment(counter.key, 1, expires_in: counter.expires_in)
        refuse!(taken, "the call counter is unavailable", CallCapReached) if count.nil?
        taken << counter
        refuse!(taken, "#{counter.name} of #{counter.limit} calls is used up", counter.error) if count > counter.limit
      end
      nil
    end

    def counters(now)
      list = [ Counter.new(day_key(now), self.class.daily_limit, DAY_TTL, "the daily limit", CallCapReached),
               Counter.new(minute_key(now), self.class.per_minute, MINUTE_TTL, "the limit a minute", MinuteCapReached) ]
      list << Counter.new(free_key(now), self.class.free_limit, DAY_TTL, "the free share", FreeShareSpent) if self.class.current_lane == :capped
      list
    end

    def refuse!(taken, reason, error)
      taken.each { |counter| @store.decrement(counter.key, 1, expires_in: counter.expires_in) }
      message = "Qloo call guard: #{reason}"
      Rails.logger.warn("[Qloo] #{message}")
      raise error, message
    end

    def wait_for_next_minute
      seconds = (60 - (@clock.call.to_f % 60) + MINUTE_MARGIN).round(1)
      Rails.logger.info("[Qloo] call guard: waiting #{seconds}s for the next minute")
      @sleeper.call(seconds)
    end

    def count(key) = @store.read(key).to_i

    def day_key(now) = "#{KEY_PREFIX}:day:#{now.utc.strftime('%Y-%m-%d')}"

    def minute_key(now) = "#{KEY_PREFIX}:minute:#{now.utc.strftime('%Y-%m-%dT%H:%M')}"

    def free_key(now) = "#{KEY_PREFIX}:capped:#{now.utc.strftime('%Y-%m-%d')}"
  end
end
