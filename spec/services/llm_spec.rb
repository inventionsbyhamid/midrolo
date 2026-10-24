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
    with_env("LLM_PROVIDER" => "fake", "ANTHROPIC_API_KEY" => "k") { expect(described_class.mode).to eq(:fake) }
  end

  it "is fake without an anthropic key outside production" do
    with_env("LLM_PROVIDER" => nil, "ANTHROPIC_API_KEY" => "") { expect(described_class.mode).to eq(:fake) }
  end

  it "is live with a key" do
    with_env("LLM_PROVIDER" => nil, "ANTHROPIC_API_KEY" => "k") { expect(described_class.mode).to eq(:live) }
  end

  it "defaults the models" do
    expect(described_class.agent_model).to eq("claude-opus-5-5")
    expect(described_class.pitch_model).to eq("claude-opus-5-5")
  end
end
