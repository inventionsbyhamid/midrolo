module Llm
  # One-shot structured (JSON schema) call. Returns a Hash with string keys and records one SpendEntry.
  # Raises Llm::FakeModeUnsupported in fake mode: callers provide their own fake path.
  class StructuredCall
    def self.call(**) = new(**).call

    def initialize(model:, schema:, instructions:, prompt:, user:, report: nil, pitch: nil)
      @model = model
      @schema = schema
      @instructions = instructions
      @prompt = prompt
      @user = user
      @report = report
      @pitch = pitch
    end

    def call
      raise FakeModeUnsupported, "structured calls need a live LLM; provide a fake path in the caller" if Llm.mode == :fake

      Pricing.ensure_known!(@model)
      bucket = Budget.bucket_for(@user)
      raise BudgetExceeded, "LLM budget exhausted for #{bucket.inspect}" unless Budget.allow?(bucket)

      response = chat.ask(@prompt)
      Budget.record!(user: @user, bucket: bucket, model: @model, tokens: token_counts(response.tokens),
                     report: @report, pitch: @pitch)
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
