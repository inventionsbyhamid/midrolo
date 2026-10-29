require "rails_helper"

RSpec.describe Llm do
  def with_env(vars)
    old = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  it "is fake when LLM_PROVIDER=fake" do
    with_env("LLM_PROVIDER" => "fake", "OPENROUTER_API_KEY" => "k") { expect(described_class.mode).to eq(:fake) }
  end

  it "is fake without the provider's key outside production" do
    with_env("LLM_PROVIDER" => nil, "OPENROUTER_API_KEY" => "", "ANTHROPIC_API_KEY" => "k") do
      expect(described_class.mode).to eq(:fake)
    end
  end

  it "is live with the provider's key" do
    with_env("LLM_PROVIDER" => nil, "OPENROUTER_API_KEY" => "k") { expect(described_class.mode).to eq(:live) }
    with_env("LLM_PROVIDER" => "anthropic", "OPENROUTER_API_KEY" => "", "ANTHROPIC_API_KEY" => "k") do
      expect(described_class.mode).to eq(:live)
    end
  end

  it "names each provider's key" do
    with_env("LLM_PROVIDER" => nil) { expect(described_class.api_key_name).to eq("OPENROUTER_API_KEY") }
    with_env("LLM_PROVIDER" => "anthropic") { expect(described_class.api_key_name).to eq("ANTHROPIC_API_KEY") }
    with_env("LLM_PROVIDER" => "gemini") { expect(described_class.api_key_name).to eq("GEMINI_API_KEY") }
  end

  it "uses low effort for pitches" do
    expect(described_class.pitch_effort).to eq(:low)
  end

  it "defaults to DeepSeek through OpenRouter" do
    with_env("LLM_PROVIDER" => nil, "LLM_AGENT_MODEL" => nil, "LLM_PITCH_MODEL" => nil) do
      expect(described_class.provider).to eq(:openrouter)
      expect(described_class.agent_model).to eq("deepseek/deepseek-v4.1-flash")
      expect(described_class.pitch_model).to eq("deepseek/deepseek-v4.1-flash")
    end
  end

  it "prices both default models" do
    expect(Llm::Pricing.known?(described_class.agent_model)).to be(true)
    expect(Llm::Pricing.known?(described_class.pitch_model)).to be(true)
  end

  it "asks OpenRouter for private hosts at no more than the priced rate, and asks other providers for nothing" do
    with_env("LLM_PROVIDER" => nil) do
      expect(described_class.provider_options("deepseek/deepseek-v4.1-flash"))
        .to eq(provider: { data_collection: "deny", max_price: { prompt: 0.3, completion: 1.2 } })
      expect { described_class.provider_options("nobody/unpriced") }.to raise_error(Llm::UnknownModel)
    end
    with_env("LLM_PROVIDER" => "anthropic") { expect(described_class.provider_options("claude-opus-5-5")).to eq({}) }
  end

  it "reads the agent's effort and limits from config" do
    expect(described_class.agent_effort).to eq(:medium)
    expect(described_class.agent_max_tool_calls).to eq(40)
    expect(described_class.agent_max_seconds).to eq(360)
  end
end
