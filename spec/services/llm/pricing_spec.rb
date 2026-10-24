require "rails_helper"

RSpec.describe Llm::Pricing do
  it "prices opus input and output per million tokens" do
    cost = described_class.cost_usd(model: "claude-opus-5-5", input: 1_000_000, output: 100_000)
    expect(cost).to be_a(BigDecimal)
    expect(cost).to eq(BigDecimal("6.0"))
  end

  it "prices cache reads and writes" do
    cost = described_class.cost_usd(model: "claude-opus-5-5", input: 0, output: 0, cache_read: 1_000_000, cache_write: 1_000_000)
    expect(cost).to eq(BigDecimal("5.2"))
  end

  it "treats a model without cache prices as free for cache tokens" do
    expect(described_class.cost_usd(model: "claude-haiku-5-5", input: 0, output: 0, cache_read: 1_000_000)).to eq(0)
  end

  it "raises for an unknown model" do
    expect { described_class.cost_usd(model: "nope", input: 1, output: 1) }.to raise_error(Llm::UnknownModel)
  end
end
