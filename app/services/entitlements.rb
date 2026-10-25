# Plans and what each allows (spec §11). Every number is in config/plans.yml (R59). A user's plan, first match wins:
#   1. an entitling subscription (Subscription.best_for: the best of several, pro = sprint > creator)
#   2. judge access (users.judge): :judge
#   3. the hackathon promo, through promo_pro_until: :promo
#   4. :free
# Entitlements::Plan answers for one user. Usage counts done reports and done pitches only (Entitlements::Usage). A
# gate (Plan#authorize!) also reserves the user's fresh in-flight work, and its callers hold lock_usage! around the
# gate and their insert (R61).
# Entitlements.for never reads request state: a public page can ask about a show's owner.
module Entitlements
  # The first key of the two-key advisory lock taken around a quota check and its insert.
  USAGE_LOCK_NAMESPACE = 16_016
  # The LLM spend bucket each plan's work draws on (R62); free work never spends.
  SPEND_BUCKETS = { free: nil, creator: :paid, pro: :paid, sprint: :paid, judge: :judge, promo: :promo }.freeze
  # The plans.yml keys a plan takes from the plan it grants (grants_plan).
  LIMIT_KEYS = %i[shows snapshots_per_month agent_reports agent_reports_total pitches visible_matches kit_badge
                  deep_scan_similar csv_export pipeline].freeze

  # reason is one of :limit, :budget, :paused, :plan. details is what the upgrade prompt shows, captured when the
  # plan refused (Plan#authorize!), so a redirect can't change its numbers: the reason, the kind and the spend
  # bucket, and for :limit the done and in-flight counts, the limit and the period they count in.
  class NotAllowed < StandardError
    attr_reader :reason

    def initialize(reason = :plan, message = nil, **details)
      @reason = reason
      @details = details
      super(message || "Not allowed: #{reason}")
    end

    def details = { reason: reason, **@details }
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
    # both pass a gate with room for one. Held until the transaction ends; outside one it would end at once, so that
    # raises.
    def lock_usage!(user)
      connection = ActiveRecord::Base.connection
      raise "Entitlements.lock_usage! must run inside a transaction" unless connection.transaction_open?

      connection.execute(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, ?)", USAGE_LOCK_NAMESPACE, user.id % 2**31 ])
      )
    end

    # A plan's name, length (a sprint's duration_days), limits and features: those of the plan it grants, overridden
    # by its own.
    def limits(key)
      own = plans.fetch(key)
      granted = own[:grants_plan] ? plans.fetch(own[:grants_plan].to_sym).slice(*LIMIT_KEYS) : {}
      granted.merge(own.slice(*LIMIT_KEYS, :name, :duration_days))
    end

    # config/plans.yml, read once. Billing reads its prices and product ids from it too.
    def plans = @plans ||= Rails.application.config_for(:plans)

    # Forgets plans.yml as read (after ENV changes, in specs).
    def reset_plans! = @plans = nil
  end
end
