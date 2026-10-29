# Provider-neutral LLM layer. Every AI call goes through here: mode, models, pricing, spend ledger, budgets.
# Never send temperature.
module Llm
  class Error < StandardError; end
  class UnknownModel < Error; end
  class BudgetExceeded < Error; end
  # Raised by one-shot structured calls in fake mode; callers provide their own fake path.
  class FakeModeUnsupported < Error; end

  # The env variable that holds each provider's key; any other provider's is <PROVIDER>_API_KEY.
  API_KEY_NAMES = { openrouter: "OPENROUTER_API_KEY", anthropic: "ANTHROPIC_API_KEY" }.freeze

  class << self
    # :fake when LLM_PROVIDER=fake, or when the provider's key is blank outside production.
    def mode
      return :fake if ENV["LLM_PROVIDER"] == "fake"
      return :fake if ENV[api_key_name].blank? && !Rails.env.production?

      :live
    end

    def fake? = mode == :fake

    def api_key_name = API_KEY_NAMES.fetch(provider) { "#{provider.to_s.upcase}_API_KEY" }

    # Merged into every request for the model as-is. OpenRouter routes only to hosts that neither store nor train on
    # prompts and charge no more than the model's prices in config/llm_pricing.yml, so the ledger is an upper bound.
    def provider_options(model)
      return {} unless provider == :openrouter

      { provider: { data_collection: "deny", max_price: Pricing.max_price(model) } }
    end

    def agent_model = config.dig(:agent, :model).to_s

    def agent_effort = (config.dig(:agent, :effort) || "medium").to_sym

    # The research agent's hard caps: tool calls per run, and wall-clock seconds.
    def agent_max_tool_calls = (config.dig(:agent, :max_tool_calls) || 40).to_i

    def agent_max_seconds = (config.dig(:agent, :max_seconds) || 360).to_i

    def pitch_model = config.dig(:pitch, :model).to_s

    def pitch_effort = (config.dig(:pitch, :effort) || "low").to_sym

    # The cheap model for bulk work (config/llm.yml cheap:): sponsor detection, a fit search's summary.
    def cheap_model = config.dig(:cheap, :model).to_s

    def provider = (config[:provider].presence || "openrouter").to_sym

    def config
      Rails.application.config_for(:llm)
    end
  end
end
