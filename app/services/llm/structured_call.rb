module Llm
  # One-shot structured (JSON schema) call. Returns a Hash with string keys and records one SpendEntry.
  # Raises Llm::FakeModeUnsupported in fake mode: callers provide their own fake path.
  #
  # The spend goes to the user's plan's bucket, or to bucket: when given (the catalog's work has no user: bucket:
  # :catalog), and is linked to the report, pitch or fit search it was for. estimate_usd is what the budget check
  # assumes the call costs (a small batch on the cheap model costs far less than a report's).
  class StructuredCall
    def self.call(**) = new(**).call

    def initialize(model:, schema:, instructions:, prompt:, user: nil, report: nil, pitch: nil, fit_search: nil,
                   bucket: nil, estimate_usd: 0.5)
      @model = model
      @schema = schema
      @instructions = instructions
      @prompt = prompt
      @user = user
      @report = report
      @pitch = pitch
      @fit_search = fit_search
      @bucket = bucket
      @estimate_usd = estimate_usd
    end

    def call
      raise FakeModeUnsupported, "structured calls need a live LLM; provide a fake path in the caller" if Llm.mode == :fake

      Pricing.ensure_known!(@model)
      bucket = @bucket || Budget.bucket_for(@user)
      raise BudgetExceeded, "LLM budget exhausted for #{bucket.inspect}" unless Budget.allow?(bucket, estimate_usd: @estimate_usd)

      response = chat.ask(@prompt)
      Budget.record!(user: @user, bucket: bucket, model: @model, tokens: token_counts(response.tokens),
                     report: @report, pitch: @pitch, fit_search: @fit_search)
      parse(response.content)
    end

    private

    def chat
      RubyLLM.chat(model: @model, provider: Llm.provider)
             .with_instructions(@instructions)
             .with_schema(@schema)
             .with_thinking(effort: Llm.pitch_effort)
             .with_provider_options(Llm.provider_options(@model))
    end

    def token_counts(tokens)
      { input: tokens&.input, output: tokens&.output, cache_read: tokens&.cache_read, cache_write: tokens&.cache_write }
    end

    def parse(content)
      content.is_a?(Hash) ? content.deep_stringify_keys : JSON.parse(content.to_s)
    end
  end
end
