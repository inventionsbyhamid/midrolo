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

  describe ".pause_runs! and .resume_runs!" do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(cache) }

    it "pauses with a reason, then resumes with no reason and the Qloo failure count cleared" do
      described_class.pause_runs!("Over budget")
      expect(described_class.runs_paused?).to be(true)
      expect(described_class.get(:runs_paused_reason)).to eq("Over budget")

      2.times { described_class.record_taste_auth_failure! }
      described_class.resume_runs!
      expect(described_class.runs_paused?).to be(false)
      expect(described_class.get(:runs_paused_reason)).to be_nil

      # The count started again: one more failure doesn't pause.
      described_class.record_taste_auth_failure!
      expect(described_class.runs_paused?).to be(false)
    end
  end

  describe "Qloo auth failures" do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(cache) }

    it "pauses runs with a reason after three failures in a row" do
      2.times { described_class.record_taste_auth_failure! }
      expect(described_class.runs_paused?).to be(false)

      described_class.record_taste_auth_failure!
      expect(described_class.runs_paused?).to be(true)
      expect(described_class.get(:runs_paused_reason)).to eq("Qloo authentication failing")
    end

    it "starts counting again after a reset" do
      2.times { described_class.record_taste_auth_failure! }
      described_class.reset_taste_auth_failures!
      2.times { described_class.record_taste_auth_failure! }
      expect(described_class.runs_paused?).to be(false)
    end
  end
end
