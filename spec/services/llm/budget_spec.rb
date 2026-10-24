require "rails_helper"

RSpec.describe Llm::Budget do
  before do
    AppSettings.set(:promo_budget_usd, 10)
    AppSettings.set(:judge_reserve_usd, 5)
    AppSettings.set(:llm_daily_budget_usd, 100)
  end

  def spend(bucket, usd, at: Time.current)
    SpendEntry.create!(bucket: bucket, kind: "llm", cost_usd: usd, created_at: at)
  end

  describe ".allow?" do
    it "never allows a nil bucket" do
      expect(described_class.allow?(nil)).to be(false)
    end

    it "blocks promo once spend plus estimate exceeds budget minus reserve" do
      spend(:promo, 4.8)
      expect(described_class.allow?(:promo, estimate_usd: 0.5)).to be(false)
      expect(described_class.allow?(:promo, estimate_usd: 0.2)).to be(true)
    end

    it "lets judge spend its reserve plus unused promo budget" do
      spend(:judge, 4.0)
      expect(described_class.allow?(:judge, estimate_usd: 0.5)).to be(true)
      spend(:judge, 0.6)
      # reserve 5 + unused promo 5 = 10 remaining ceiling
      expect(described_class.allow?(:judge, estimate_usd: 0.5)).to be(true)
      spend(:judge, 5.0)
      expect(described_class.allow?(:judge, estimate_usd: 0.5)).to be(false)
    end

    it "shrinks the judge ceiling as promo spend grows" do
      spend(:promo, 5.0)
      spend(:judge, 4.8)
      expect(described_class.allow?(:judge, estimate_usd: 0.5)).to be(false)
    end

    it "applies the daily cap to promo and paid only" do
      AppSettings.set(:llm_daily_budget_usd, 5)
      spend(:dev, 5.0)
      expect(described_class.allow?(:promo, estimate_usd: 0)).to be(false)
      expect(described_class.allow?(:paid, estimate_usd: 0)).to be(false)
      expect(described_class.allow?(:judge, estimate_usd: 0.5)).to be(true)
      expect(described_class.allow?(:dev)).to be(true)
      expect(described_class.allow?(:sample)).to be(true)
    end

    it "ignores yesterday's spend for the daily cap" do
      AppSettings.set(:llm_daily_budget_usd, 5)
      spend(:paid, 6.0, at: 2.days.ago)
      expect(described_class.allow?(:paid, estimate_usd: 0.5)).to be(true)
    end

    it "blocks every bucket except dev when runs are paused" do
      AppSettings.set(:runs_paused, true)
      %i[promo judge paid sample].each { |b| expect(described_class.allow?(b)).to be(false) }
      expect(described_class.allow?(:dev)).to be(true)
    end
  end

  describe ".bucket_for" do
    it "returns judge for judges" do
      expect(described_class.bucket_for(build(:user, judge: true))).to eq(:judge)
    end

    it "returns promo while the promo is active" do
      AppSettings.set(:promo_pro_until, Date.current.to_s)
      expect(described_class.bucket_for(build(:user))).to eq(:promo)
    end

    it "returns nil after the promo ends or when unset" do
      AppSettings.set(:promo_pro_until, 1.day.ago.to_date.to_s)
      expect(described_class.bucket_for(build(:user))).to be_nil
      AppSettings.set(:promo_pro_until, "garbage")
      expect(described_class.bucket_for(build(:user))).to be_nil
    end
  end

  describe ".record!" do
    it "stores tokens and our own computed cost" do
      user = create(:user)
      entry = described_class.record!(user: user, bucket: :promo, model: "claude-opus-5-5",
                                      tokens: { input: 1_000_000, output: 100_000 })
      expect(entry).to be_persisted
      expect(entry.cost_usd).to eq(BigDecimal("6.0"))
      expect(entry).to have_attributes(bucket: "promo", kind: "llm", input_tokens: 1_000_000, cache_read_tokens: 0)
    end

    it "accepts report and pitch ids" do
      report = create(:report)
      entry = described_class.record!(user: nil, bucket: :dev, model: "claude-opus-5-5", tokens: {}, report: report)
      expect(entry.report_id).to eq(report.id)
    end

    it "records a taste entry at zero cost without a priced model" do
      entry = described_class.record!(user: nil, bucket: :dev, model: nil, tokens: {}, kind: :taste)
      expect(entry.cost_usd).to eq(0)
    end
  end
end
