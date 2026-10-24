# Provider-neutral LLM layer. Every AI call goes through here: mode, models, pricing, spend ledger, budgets.
# Never send temperature.
module Llm
  class Error < StandardError; end
  class UnknownModel < Error; end
  class BudgetExceeded < Error; end
  # Raised by one-shot structured calls in fake mode; callers provide their own fake path.
  class FakeModeUnsupported < Error; end

  class << self
    # :fake when LLM_PROVIDER=fake, or when ANTHROPIC_API_KEY is blank outside production.
    def mode
      return :fake if ENV["LLM_PROVIDER"] == "fake"
      return :fake if ENV["ANTHROPIC_API_KEY"].blank? && !Rails.env.production?

      :live
    end

    def fake? = mode == :fake

    def agent_model = config.dig(:agent, :model).to_s

    def pitch_model = config.dig(:pitch, :model).to_s

    def pitch_effort = (config.dig(:pitch, :effort) || "low").to_sym

    def provider = (config[:provider].presence || "anthropic").to_sym

    def config
      Rails.application.config_for(:llm)
    end
  end
end
