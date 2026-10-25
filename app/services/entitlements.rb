# Plans and what each allows (spec §11). Every number is in config/plans.yml (R59). A user's plan, first match wins:
#   1. an entitling subscription (Subscription.best_for: the best of several, pro = sprint > creator)
#   2. judge access (users.judge): :judge
#   3. the hackathon promo, through promo_pro_until: :promo
#   4. :free
# Usage counts done reports and done pitches only (Entitlements::Usage). A gate (Plan#authorize!) also reserves the
# user's fresh in-flight work, and its callers hold lock_usage! around the gate and their insert (R61).
# Entitlements.for never reads request state: a public page can ask about a show's owner.
module Entitlements
  # The first key of the two-key advisory lock taken around a quota check and its insert.
  USAGE_LOCK_NAMESPACE = 16_016
  # The LLM spend bucket each plan's work draws on (R62); free work never spends.
  SPEND_BUCKETS = { free: nil, creator: :paid, pro: :paid, sprint: :paid, judge: :judge, promo: :promo }.freeze
  # The plans.yml keys a plan takes from the plan it grants (grants_plan).
  LIMIT_KEYS = %i[shows snapshots_per_month agent_reports agent_reports_total pitches visible_matches kit_badge
                  deep_scan_similar csv_export pipeline].freeze

  # reason is one of :limit, :budget, :paused, :plan
  class NotAllowed < StandardError
    attr_reader :reason

    def initialize(reason = :plan, message = nil)
      @reason = reason
      super(message || "Not allowed: #{reason}")
    end
  end

  class << self
    def for(user)
      return Plan.new(:free) if user.nil?

      subscription = Subscription.best_for(user)
      key = if subscription then subscription.plan.to_sym
      elsif user.judge? then :judge
      elsif promo_active? then :promo
      else :free
      end
      Plan.new(key, user: user, subscription: subscription)
    end

    # The promo's last day (promo_pro_until), or nil when unset or unreadable.
    def promo_until
      Date.parse(AppSettings.get(:promo_pro_until).to_s)
    rescue Date::Error
      nil
    end

    # The one promo check (R62), inclusive through promo_pro_until: plans and spend buckets both follow it.
    def promo_active?
      last_day = promo_until
      last_day.present? && last_day >= Date.current
    end

    # Serializes one user's quota checks with their inserts (Report.start!, pitch create), so parallel requests can't
    # both pass a gate with room for one. Held until the transaction ends, so call it inside one.
    def lock_usage!(user)
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, ?)", USAGE_LOCK_NAMESPACE, user.id % 2**31 ])
      )
    end

    # A plan's name, limits and features: those of the plan it grants, overridden by its own.
    def limits(key)
      own = plans.fetch(key)
      granted = own[:grants_plan] ? plans.fetch(own[:grants_plan].to_sym).slice(*LIMIT_KEYS) : {}
      granted.merge(own.slice(*LIMIT_KEYS), name: own.fetch(:name))
    end

    private

    def plans = @plans ||= Rails.application.config_for(:plans)
  end

  class Plan
    # What a gate is asked about: a report of either kind, or a pitch pack.
    KINDS = %i[snapshot agent pitch].freeze
    LIMITS = { snapshot: :snapshots_per_month, agent: :agent_reports, pitch: :pitches }.freeze

    attr_reader :key

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
    def can_pitch? = limit(:pitch).positive?

    # A judge's work always draws on the judge reserve, even on a paid plan (R62a).
    def spend_bucket = @user&.judge? ? :judge : SPEND_BUCKETS.fetch(key)

    # Where this period's usage starts: the subscription's period, else the calendar month.
    def period_start = billing_period_start || Time.current.beginning_of_month
    def period_name = billing_period_start ? "billing period" : "month"

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

    # The X of "You've used X of Y", counted as the gate counts: done work (up to the limit) plus work in flight.
    def in_use(kind)
      kind = kind.to_sym
      limit(kind).infinite? ? used(kind) + in_flight(kind) : limit(kind) - left_now(kind) + in_flight(kind)
    end

    def agent_reports_left(period_start = nil) = left(:agent, since: period_start || self.period_start)
    def snapshots_left = left(:snapshot)
    def pitches_left = left(:pitch)

    def can_run?(kind) = refusal(kind).nil?

    def authorize!(kind)
      reason = refusal(kind)
      raise NotAllowed, reason if reason
    end

    # Why the plan won't start one more now, or nil: :paused (the kill switch, before anything else), :plan (not on
    # this plan), :limit (done and in-flight work fill the limit) or :budget (the spend bucket is out of money).
    # Snapshots spend nothing on the LLM, so only the others ask the budget.
    def refusal(kind)
      kind = kind.to_sym
      raise ArgumentError, "unknown kind #{kind.inspect}" unless KINDS.include?(kind)
      return :paused if AppSettings.runs_paused?
      return :plan unless kind == :pitch ? can_pitch? : limit(kind).positive?
      return :limit if left_now(kind) - in_flight(kind) <= 0
      return :budget if kind != :snapshot && !Llm::Budget.allow?(spend_bucket)

      nil
    end

    private

    def total_bucket = SPEND_BUCKETS.fetch(key)

    def billing_period_start = @subscription&.current_period_start

    def left(kind, since: period_start) = [ limit(kind) - used(kind, since: since), 0 ].max

    # What's left of the kind, read through the public answers, so a plan that overrides them is gated by what it says.
    def left_now(kind)
      case kind
      when :snapshot then snapshots_left
      when :agent then agent_reports_left
      else pitches_left
      end
    end
  end
end
