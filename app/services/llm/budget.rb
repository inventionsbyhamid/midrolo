module Llm
  # Keeps the product profitable and caps promo/judge usage. Totals for promo and judge are all-time (since launch);
  # the daily cap covers today's spend across every bucket but only blocks :promo and :paid.
  module Budget
    DAILY_CAPPED = %i[promo paid].freeze

    class << self
      def bucket_for(user)
        return :judge if user.judge
        return :promo if promo_active?

        nil
      end

      def allow?(bucket, estimate_usd: 0.5)
        return false if bucket.nil?

        bucket = bucket.to_sym
        return true if bucket == :dev
        return false if AppSettings.runs_paused?

        estimate = dec(estimate_usd)
        return false if DAILY_CAPPED.include?(bucket) && daily_cap_reached?(estimate)

        case bucket
        when :promo then spent(:promo) + estimate <= promo_ceiling
        when :judge then spent(:judge) + estimate <= judge_ceiling
        else true
        end
      end

      def record!(user:, bucket:, model:, tokens:, kind: :llm, report: nil, pitch: nil)
        tokens = (tokens || {}).to_h.transform_keys(&:to_sym)
        counts = %i[input output cache_read cache_write].index_with { |k| tokens[k].to_i }
        cost = model.present? ? Pricing.cost_usd(model: model, **counts) : BigDecimal("0")
        SpendEntry.create!(
          user: user, report_id: report&.id, pitch_id: pitch&.id, kind: kind.to_s, bucket: bucket.to_s, model: model,
          input_tokens: counts[:input], output_tokens: counts[:output], cache_read_tokens: counts[:cache_read],
          cache_write_tokens: counts[:cache_write], cost_usd: cost
        )
      end

      private

      def daily_cap_reached?(estimate)
        cap = setting(:llm_daily_budget_usd, 5)
        today = spent_today
        today >= cap || today + estimate > cap
      end

      def promo_ceiling = setting(:promo_budget_usd, 10) - setting(:judge_reserve_usd, 5)

      def judge_ceiling
        reserve = setting(:judge_reserve_usd, 5)
        reserve + [ promo_ceiling - spent(:promo), 0 ].max
      end

      def promo_active?
        until_date = Date.parse(AppSettings.get(:promo_pro_until).to_s)
        until_date >= Date.current
      rescue Date::Error
        false
      end

      def spent(bucket) = SpendEntry.where(bucket: bucket.to_s).sum(:cost_usd)

      def spent_today = SpendEntry.today.sum(:cost_usd)

      def setting(key, default) = dec(AppSettings.get(key, default: default))

      def dec(value) = BigDecimal(value.to_s)
    end
  end
end
