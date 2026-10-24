# Runtime-tunable settings. A stored Setting row wins, then ENV (KEY upcased), then the default.
class AppSettings
  KEYS = %i[promo_budget_usd judge_reserve_usd llm_daily_budget_usd runs_paused runs_paused_reason promo_pro_until].freeze
  # Qloo 401/403s in a row (counted in Rails.cache) before new runs pause themselves (Review Focus #4).
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

    # One more Qloo auth failure in a row; the third pauses new runs. Returns the count.
    def record_taste_auth_failure!
      count = Rails.cache.increment(TASTE_AUTH_FAILURES_KEY, 1, expires_in: 1.day).to_i
      if count >= TASTE_AUTH_FAILURE_LIMIT && !runs_paused?
        set(:runs_paused, true)
        set(:runs_paused_reason, TASTE_AUTH_PAUSE_REASON)
      end
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
