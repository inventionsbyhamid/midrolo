module Entitlements
  # One user's plan: its limits and features (config/plans.yml through Entitlements.limits), what they've used, and
  # the gate (authorize!) that says whether one more report or pitch may start. Every answer, the gate's included,
  # derives from the same limits and usage, so the predicates and the gate can't disagree.
  class Plan
    # What a gate is asked about: a report of either kind, or a pitch pack.
    KINDS = %i[snapshot agent pitch].freeze
    LIMITS = { snapshot: :snapshots_per_month, agent: :agent_reports, pitch: :pitches }.freeze
    # A subscription period up to this long (a monthly plan, the 30-day sprint) is one usage window; a longer one
    # (yearly) is counted month by month from its start (R60a).
    SINGLE_WINDOW = 31.days

    # subscription: the Subscription the plan comes from (nil for judge, promo and free), for its renewal date.
    attr_reader :key, :subscription

    def initialize(key, user: nil, subscription: nil)
      @key = key.to_sym
      @user = user
      @subscription = subscription
      @limits = Entitlements.limits(@key)
      @usage = Usage.new(user)
    end

    def name = @limits.fetch(:name)
    def max_shows = @limits.fetch(:shows)
    def visible_matches_limit = @limits.fetch(:visible_matches)
    def kit_badge? = @limits.fetch(:kit_badge)
    def csv_export? = @limits.fetch(:csv_export)
    def pipeline? = @limits.fetch(:pipeline)
    def scan_limit = @limits.fetch(:deep_scan_similar)
    def duration_days = @limits[:duration_days]
    def can_pitch? = limit(:pitch).positive?

    # Whether this user's Snapshots and reports run in the capped Qloo lane (R108).
    def capped_taste? = CAPPED_TASTE_PLANS.include?(key)

    # A judge's work always draws on the judge reserve, even on a paid plan (R62a).
    def spend_bucket = @user&.judge? ? :judge : SPEND_BUCKETS.fetch(key)

    # Where this period's usage starts (R60a): a subscription's current usage window, else the calendar month.
    def period_start = billing_window_start || Time.current.beginning_of_month

    # "billing period" when the window is the subscription's whole period; "month" for a calendar month or a month
    # of a longer (yearly) period.
    def period_name = billing_window_start && single_window? ? "billing period" : "month"

    # How many the plan allows per period (or in total, see counted_in_total?); Float::INFINITY when unlimited.
    def limit(kind)
      value = @limits.fetch(LIMITS.fetch(kind.to_sym))
      value == "unlimited" ? Float::INFINITY : value
    end

    # Judge and promo agent reports count all time, in the plan's own spend bucket.
    def counted_in_total?(kind) = kind.to_sym == :agent && @limits[:agent_reports_total] == true

    # Done work counted against the limit.
    def used(kind, since: period_start)
      kind = kind.to_sym
      counted_in_total?(kind) ? @usage.done(kind, bucket: total_bucket) : @usage.done(kind, since: since)
    end

    # Fresh work still queued or running, which a gate reserves.
    def in_flight(kind)
      kind = kind.to_sym
      @usage.in_flight(kind, bucket: (total_bucket if counted_in_total?(kind)))
    end

    def agent_reports_left(period_start = nil) = left(:agent, since: period_start || self.period_start)
    def snapshots_left = left(:snapshot)
    def pitches_left = left(:pitch)

    def can_run?(kind) = refusal(kind).nil?

    # Raises NotAllowed with the reason and what the upgrade prompt should say, as things stand now.
    def authorize!(kind)
      kind = kind.to_sym
      reason = refusal(kind)
      raise NotAllowed.new(reason, **refusal_details(reason, kind)) if reason
    end

    # Why the plan won't start one more now, or nil: :paused (the kill switch, before anything else), :plan (not on
    # this plan), :limit (done and in-flight work fill the limit), :budget (the spend bucket is out of money) or :busy
    # (a capped user's share of today's Qloo calls is used up, R108). Snapshots spend nothing on the LLM, so only the
    # others ask the budget; pitches make no Qloo calls, so they are never busy.
    def refusal(kind)
      kind = kind.to_sym
      raise ArgumentError, "unknown kind #{kind.inspect}" unless KINDS.include?(kind)
      return :paused if AppSettings.runs_paused?
      return :plan unless limit(kind).positive?
      return :limit if left(kind) - in_flight(kind) <= 0
      return :budget if kind != :snapshot && !Llm::Budget.allow?(spend_bucket)
      return :busy if kind != :pitch && capped_taste? && Taste::CallGuard.new.capped_spent?

      nil
    end

    private

    def total_bucket = SPEND_BUCKETS.fetch(key)

    def left(kind, since: period_start) = [ limit(kind) - used(kind, since: since), 0 ].max

    # The upgrade prompt's numbers for a :limit refusal: done and in-flight work, the limit, and the period they
    # count in (none when the plan counts in total). The bucket picks the :budget wording (R63a).
    def refusal_details(reason, kind)
      details = { kind: kind, bucket: spend_bucket }
      return details unless reason == :limit

      details.merge(used: used(kind), in_flight: in_flight(kind), limit: limit(kind),
                    period: (period_name unless counted_in_total?(kind)))
    end

    # The subscription's period when it is one window; for a longer one, its latest monthly anniversary up to now
    # (a Jan 31 start falls on Feb 28 or 29), never past the period's end. nil without a period start.
    def billing_window_start
      start = @subscription&.current_period_start
      return start if start.nil? || single_window?

      now = Time.current
      months = (now.year - start.year) * 12 + now.month - start.month
      months -= 1 if start.advance(months: months) > now
      window = start.advance(months: [ months, 0 ].max)
      period_end = @subscription.current_period_end
      period_end ? [ window, period_end ].min : window
    end

    def single_window?
      period_end = @subscription.current_period_end
      period_end.present? && period_end - @subscription.current_period_start <= SINGLE_WINDOW
    end
  end
end
