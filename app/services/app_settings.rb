# Runtime-tunable settings. A stored Setting row wins, then ENV (KEY upcased), then the default.
class AppSettings
  KEYS = %i[promo_budget_usd judge_reserve_usd llm_daily_budget_usd runs_paused runs_paused_reason promo_pro_until
            qloo_daily_call_limit qloo_cost_per_call_usd qloo_free_share].freeze
  # Qloo 401s in a row (counted in Rails.cache) before new runs pause themselves (Review Focus #4). A 403 never counts
  # (R87).
  TASTE_AUTH_FAILURE_LIMIT = 3
  TASTE_AUTH_FAILURES_KEY = "app_settings:taste_auth_failures".freeze
  TASTE_AUTH_PAUSE_REASON = "Qloo authentication failing".freeze

  class << self
    def get(key, default: nil)
      row = Setting.find_by(key: key.to_s)
      return row.value if row

      env = ENV[key.to_s.upcase]
      return default if env.blank?

      parse(env)
    end

    def set(key, value)
      setting = Setting.find_or_initialize_by(key: key.to_s)
      setting.update!(value: value)
      value
    end

    def runs_paused?
      get(:runs_paused, default: false) == true
    end

    # The kill switch: new reports, Snapshots and pitches refuse with :paused, and the upgrade prompt shows reason.
    def pause_runs!(reason)
      set(:runs_paused, true)
      set(:runs_paused_reason, reason)
    end

    # Lifts the kill switch. The Qloo failure count starts again too, so a single failure after resuming can't pause
    # runs at once.
    def resume_runs!
      set(:runs_paused, false)
      set(:runs_paused_reason, nil)
      reset_taste_auth_failures!
    end

    # One more Qloo auth failure in a row; the third pauses new runs. Returns the count.
    def record_taste_auth_failure!
      count = Rails.cache.increment(TASTE_AUTH_FAILURES_KEY, 1, expires_in: 1.day).to_i
      pause_runs!(TASTE_AUTH_PAUSE_REASON) if count >= TASTE_AUTH_FAILURE_LIMIT && !runs_paused?
      count
    end

    # Called after a run whose Qloo calls succeeded: the failures are no longer "in a row".
    def reset_taste_auth_failures!
      Rails.cache.delete(TASTE_AUTH_FAILURES_KEY)
    end

    private

    def parse(raw)
      JSON.parse(raw)
    rescue JSON::ParserError
      raw
    end
  end
end
