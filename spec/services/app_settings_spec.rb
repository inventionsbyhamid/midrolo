require "rails_helper"

RSpec.describe AppSettings do
  it "returns the default when unset" do
    expect(described_class.get(:promo_budget_usd, default: 10)).to eq(10)
  end

  it "returns the stored value after set" do
    described_class.set(:promo_budget_usd, 12)
    expect(described_class.get(:promo_budget_usd, default: 10)).to eq(12)
  end

  it "overwrites an existing value" do
    described_class.set(:promo_budget_usd, 12)
    described_class.set(:promo_budget_usd, 7)
    expect(Setting.where(key: "promo_budget_usd").count).to eq(1)
    expect(described_class.get(:promo_budget_usd, default: 10)).to eq(7)
  end

  it "is not paused by default" do
    expect(described_class.runs_paused?).to be(false)
  end

  it "pauses when set" do
    described_class.set(:runs_paused, true)
    expect(described_class.runs_paused?).to be(true)
  end
end
