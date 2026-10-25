require "rails_helper"

RSpec.describe Admin::SettingsForm do
  let(:valid) do
    { promo_budget_usd: "10", judge_reserve_usd: "5", llm_daily_budget_usd: "5", promo_pro_until: "2026-11-06",
      qloo_daily_call_limit: "100" }
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
