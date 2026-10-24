# Runtime-tunable settings. A stored Setting row wins, then ENV (KEY upcased), then the default.
class AppSettings
  KEYS = %i[promo_budget_usd judge_reserve_usd llm_daily_budget_usd runs_paused promo_pro_until].freeze

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

    private

    def parse(raw)
      JSON.parse(raw)
    rescue JSON::ParserError
      raw
    end
  end
end
