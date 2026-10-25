# The admin page's budget, promo and Qloo settings (R68, R92), kept as typed so a refused form shows what was entered.
# Saving validates every value, then writes through AppSettings, in one transaction, only the ones that changed,
# normalized; changed_settings says what changed from what, for the log. Llm::Budget, Entitlements and
# Taste::CallGuard read the values back.
module Admin
  class SettingsForm
    include ActiveModel::Model
    include ActiveModel::Attributes

    BUDGET_KEYS = Llm::Budget::DEFAULTS.keys.freeze
    LABELS = { promo_budget_usd: "Promo budget", judge_reserve_usd: "Judge reserve",
               llm_daily_budget_usd: "Daily LLM budget", promo_pro_until: "Promo Pro until",
               qloo_daily_call_limit: "Qloo calls a day" }.freeze
    # Whole dollars or dollars and cents, never negative: "10", "0.5", ".5".
    DOLLARS = /\A(?:\d+(?:\.\d+)?|\.\d+)\z/
    WHOLE_NUMBER = /\A\d+\z/

    BUDGET_KEYS.each { |key| attribute key, :string }
    attribute :promo_pro_until, :string
    attribute :qloo_daily_call_limit, :string

    validate :budgets_are_dollars, :reserve_fits_budget, :promo_date_is_a_date, :call_limit_is_a_whole_number

    # The values in force now.
    def self.current
      new(**BUDGET_KEYS.index_with { |key| Llm::Budget.setting(key).to_s("F") },
          promo_pro_until: Entitlements.promo_until&.iso8601,
          qloo_daily_call_limit: Taste::CallGuard.daily_limit.to_s)
    end

    def self.human_attribute_name(attribute, options = {}) = LABELS.fetch(attribute.to_sym) { super }

    def changed_settings = @changed_settings || []

    def save
      @changed_settings = []
      return false unless valid?

      before = self.class.current
      Setting.transaction do
        normalized.each do |key, value|
          was = before.public_send(key)
          next if was == value

          AppSettings.set(key, value)
          @changed_settings << "#{key} from #{was || 'unset'} to #{value}"
        end
      end
      true
    end

    private

    def normalized
      BUDGET_KEYS.index_with { |key| dollars(key).to_s("F") }
                 .merge(promo_pro_until: promo_date.iso8601, qloo_daily_call_limit: call_limit.to_s)
    end

    def dollars(key)
      value = public_send(key).to_s.strip
      BigDecimal(value) if DOLLARS.match?(value)
    end

    def promo_date
      Date.iso8601(promo_pro_until.to_s.strip)
    rescue Date::Error
      nil
    end

    def call_limit
      value = qloo_daily_call_limit.to_s.strip
      Integer(value, 10) if WHOLE_NUMBER.match?(value)
    end

    def budgets_are_dollars
      BUDGET_KEYS.each { |key| errors.add(key, "must be a dollar amount, 0 or more.") unless dollars(key) }
    end

    def reserve_fits_budget
      budget, reserve = dollars(:promo_budget_usd), dollars(:judge_reserve_usd)
      return unless budget && reserve && reserve > budget

      errors.add(:judge_reserve_usd, "can't be more than the promo budget.")
    end

    def promo_date_is_a_date
      errors.add(:promo_pro_until, "must be a date.") unless promo_date
    end

    def call_limit_is_a_whole_number
      errors.add(:qloo_daily_call_limit, "must be a whole number, 0 or more.") unless call_limit
    end
  end
end
