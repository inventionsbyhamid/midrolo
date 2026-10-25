require "rails_helper"

RSpec.describe Admin::SettingsForm do
  let(:valid) do
    { promo_budget_usd: "10", judge_reserve_usd: "5", llm_daily_budget_usd: "5", promo_pro_until: "2026-11-06",
      qloo_daily_call_limit: "100", qloo_cost_per_call_usd: "", qloo_free_share: "0.4" }
  end

  def form(**changes) = described_class.new(**valid, **changes)

  describe ".current" do
    it "shows the budgets' defaults and a blank promo date when nothing is set" do
      expect(described_class.current).to have_attributes(promo_budget_usd: "10.0", judge_reserve_usd: "5.0",
                                                         llm_daily_budget_usd: "5.0", promo_pro_until: nil)
    end

    it "shows the Qloo daily call limit, 100 by default (R92)" do
      expect(described_class.current.qloo_daily_call_limit).to eq("100")
      AppSettings.set(:qloo_daily_call_limit, "250")
      expect(described_class.current.qloo_daily_call_limit).to eq("250")
    end

    it "shows the Qloo cost per call, blank until it is set (R94)" do
      expect(described_class.current.qloo_cost_per_call_usd).to eq("")
      AppSettings.set(:qloo_cost_per_call_usd, "0.0025")
      expect(described_class.current.qloo_cost_per_call_usd).to eq("0.0025")
    end

    it "shows the free Snapshots' share of the daily Qloo calls, 0.4 by default (R95)" do
      expect(described_class.current.qloo_free_share).to eq("0.4")
      AppSettings.set(:qloo_free_share, "0.25")
      expect(described_class.current.qloo_free_share).to eq("0.25")
    end

    it "shows what is set" do
      AppSettings.set(:promo_budget_usd, 12)
      AppSettings.set(:llm_daily_budget_usd, "2.5")
      AppSettings.set(:promo_pro_until, "2026-11-06")
      expect(described_class.current).to have_attributes(promo_budget_usd: "12.0", llm_daily_budget_usd: "2.5",
                                                         promo_pro_until: "2026-11-06")
    end
  end

  describe "validation" do
    it "takes dollar amounts of 0 or more, with or without cents and around spaces" do
      expect(form(promo_budget_usd: " 12.34 ", judge_reserve_usd: "0", llm_daily_budget_usd: ".5")).to be_valid
    end

    it "refuses negatives, words, blanks, exponents and thousands separators" do
      [ "-1", "lots", "", "1e3", "1,000", "5." ].each do |value|
        record = form(llm_daily_budget_usd: value)
        expect(record).not_to be_valid, "expected #{value.inspect} to be refused"
        expect(record.errors.full_messages).to eq([ "Daily LLM budget must be a dollar amount, 0 or more." ])
      end
    end

    it "refuses a judge reserve bigger than the promo budget" do
      record = form(promo_budget_usd: "4", judge_reserve_usd: "5")
      expect(record).not_to be_valid
      expect(record.errors.full_messages).to eq([ "Judge reserve can't be more than the promo budget." ])
      expect(form(promo_budget_usd: "5", judge_reserve_usd: "5")).to be_valid
    end

    it "takes a whole number of Qloo calls a day, 0 or more (R92)" do
      expect(form(qloo_daily_call_limit: " 0 ")).to be_valid
      [ "-1", "1.5", "lots", "", "1e3" ].each do |value|
        record = form(qloo_daily_call_limit: value)
        expect(record).not_to be_valid, "expected #{value.inspect} to be refused"
        expect(record.errors.full_messages).to eq([ "Qloo calls a day must be a whole number, 0 or more." ])
      end
    end

    it "takes a Qloo cost per call in dollars, 0 or more, or blank for unset (R94)" do
      [ "", " ", "0", "0.0015", ".002" ].each { |value| expect(form(qloo_cost_per_call_usd: value)).to be_valid, "expected #{value.inspect}" }
      [ "-1", "lots", "1e-3", "$0.01" ].each do |value|
        record = form(qloo_cost_per_call_usd: value)
        expect(record).not_to be_valid, "expected #{value.inspect} to be refused"
        expect(record.errors.full_messages).to eq([ "Qloo cost per call must be a dollar amount, 0 or more, or blank." ])
      end
    end

    it "takes a free share from 0 to 1 (R95)" do
      [ "0", "0.4", "1", ".5", "1.0" ].each { |value| expect(form(qloo_free_share: value)).to be_valid, "expected #{value.inspect}" }
      [ "", "-0.1", "1.01", "40%", "lots" ].each do |value|
        record = form(qloo_free_share: value)
        expect(record).not_to be_valid, "expected #{value.inspect} to be refused"
        expect(record.errors.full_messages).to eq([ "Free Snapshot share of Qloo calls must be from 0 to 1, like 0.4." ])
      end
    end

    it "needs a real date for the promo" do
      [ "", "2026-13-40", "next week" ].each do |value|
        record = form(promo_pro_until: value)
        expect(record).not_to be_valid, "expected #{value.inspect} to be refused"
        expect(record.errors.full_messages).to eq([ "Promo Pro until must be a date." ])
      end
    end
  end

  describe "#save" do
    it "writes only what changed, normalized, and says what changed from what" do
      AppSettings.set(:promo_pro_until, "2026-11-06")
      record = form(promo_budget_usd: "12.50", promo_pro_until: "2026-11-06")

      expect(record.save).to be(true)

      expect(AppSettings.get(:promo_budget_usd)).to eq("12.5")
      expect(Setting.pluck(:key)).to contain_exactly("promo_budget_usd", "promo_pro_until")
      expect(record.changed_settings).to eq([ "promo_budget_usd from 10.0 to 12.5" ])
    end

    it "saves the Qloo daily call limit the call guard reads (R92)" do
      AppSettings.set(:promo_pro_until, "2026-11-06")
      record = form(qloo_daily_call_limit: "0250")

      expect(record.save).to be(true)
      expect(record.changed_settings).to eq([ "qloo_daily_call_limit from 100 to 250" ])
      expect(Taste::CallGuard.daily_limit).to eq(250)
    end

    it "sets the Qloo cost per call, and clears it again when blanked (R94)" do
      AppSettings.set(:promo_pro_until, "2026-11-06")
      record = form(qloo_cost_per_call_usd: " 0.0020 ")
      expect(record.save).to be(true)
      expect(record.changed_settings).to eq([ "qloo_cost_per_call_usd from unset to 0.002" ])
      expect(Billing::Margins.cost_per_call).to eq(BigDecimal("0.002"))

      record = form(qloo_cost_per_call_usd: "")
      expect(record.save).to be(true)
      expect(record.changed_settings).to eq([ "qloo_cost_per_call_usd from 0.002 to unset" ])
      expect(Billing::Margins.cost_per_call).to be_nil
    end

    it "saves the free share the call guard reads (R95)" do
      AppSettings.set(:promo_pro_until, "2026-11-06")
      record = form(qloo_free_share: "0.30")
      expect(record.save).to be(true)
      expect(record.changed_settings).to eq([ "qloo_free_share from 0.4 to 0.3" ])
      expect(Taste::CallGuard.free_share).to eq(BigDecimal("0.3"))
    end

    it "changes nothing when every value is as it was" do
      AppSettings.set(:promo_pro_until, "2026-11-06")
      record = form(promo_budget_usd: "10.00")
      expect(record.save).to be(true)
      expect(record.changed_settings).to be_empty
      expect(Setting.pluck(:key)).to eq([ "promo_pro_until" ])
    end

    it "writes nothing when a write fails part way" do
      AppSettings.set(:promo_pro_until, "2026-11-06")
      allow(AppSettings).to receive(:set).and_call_original
      allow(AppSettings).to receive(:set).with(:judge_reserve_usd, anything).and_raise(ActiveRecord::StatementInvalid)

      expect { form(promo_budget_usd: "20", judge_reserve_usd: "6").save }.to raise_error(ActiveRecord::StatementInvalid)
      expect(Setting.pluck(:key)).to eq([ "promo_pro_until" ])
    end

    it "saves nothing when anything is invalid" do
      record = form(promo_budget_usd: "20", promo_pro_until: "soon")
      expect(record.save).to be(false)
      expect(record.changed_settings).to be_empty
      expect(Setting.count).to eq(0)
    end
  end
end
