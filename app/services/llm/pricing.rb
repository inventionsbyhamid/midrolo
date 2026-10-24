module Llm
  # Our own price table (config/llm_pricing.yml, USD per 1M tokens). Not the RubyLLM registry.
  module Pricing
    PER = BigDecimal("1000000")

    class << self
      def cost_usd(model:, input:, output:, cache_read: 0, cache_write: 0)
        prices = table[model.to_s] or raise UnknownModel, "no pricing for model #{model.inspect}"
        total = (input.to_i * price(prices, :input)) + (output.to_i * price(prices, :output)) +
                (cache_read.to_i * price(prices, :cache_read)) + (cache_write.to_i * price(prices, :cache_write))
        total / PER
      end

      private

      def price(prices, key) = BigDecimal((prices[key] || 0).to_s)

      def table
        Rails.application.config_for(:llm_pricing).to_h.transform_keys(&:to_s)
      end
    end
  end
end
