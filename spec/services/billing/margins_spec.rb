require "rails_helper"

RSpec.describe Billing::Margins do
  def row(key) = described_class.check.rows.find { |row| row.price.key == key }

  describe "margin at caps per paid price (R94)" do
    it "nets each price after worst case Dodo fees (6% + $0.40) and costs the LLM at the plan's caps, as docs/design.md tabulates" do
      AppSettings.set(:qloo_cost_per_call_usd, "0")

      expect(described_class.check.rows.map { |row| row.price.key }).to eq(%w[creator_monthly creator_yearly pro_monthly pro_yearly sprint])
      expect(row("creator_monthly")).to have_attributes(net_usd: BigDecimal("17.46"), llm_usd: BigDecimal("3.6"))
      expect(row("pro_monthly")).to have_attributes(net_usd: BigDecimal("45.66"), llm_usd: BigDecimal("12"))
      expect(row("sprint")).to have_attributes(net_usd: BigDecimal("45.66"), llm_usd: BigDecimal("12"))
      # A yearly plan counts its caps month by month (R60a): 12 months of them on one payment.
      expect(row("creator_yearly")).to have_attributes(net_usd: BigDecimal("178.2"), llm_usd: BigDecimal("43.2"))
      expect(row("pro_yearly")).to have_attributes(net_usd: BigDecimal("460.2"), llm_usd: BigDecimal("144"))
      expect(row("creator_monthly").margin.round(4)).to eq(BigDecimal("0.7938"))
    end

    it "counts Qloo calls at caps for every full report and Snapshot, at the research cap per report" do
      AppSettings.set(:qloo_cost_per_call_usd, "0.001")

      expect(row("creator_monthly")).to have_attributes(qloo_calls: (4 + 4) * 30, qloo_usd: BigDecimal("0.24"))
      expect(row("pro_monthly").qloo_calls).to eq((12 + 12) * 30)
      expect(row("pro_yearly").qloo_calls).to eq((12 + 12) * 30 * 12)
      expect(row("sprint").qloo_calls).to eq((12 + 12) * 30)
      expect(row("creator_monthly").margin).to eq((BigDecimal("17.46") - BigDecimal("3.6") - BigDecimal("0.24")) / BigDecimal("17.46"))
    end

    it "uses the measured averages when they are higher than the estimates, never when lower" do
      show = create(:show)
      create(:report, show: show, kind: "agent", status: "done", cost_usd: 0.9, taste_calls: 50)
      create(:report, show: show, kind: "agent", status: "done", cost_usd: 0.7, taste_calls: 40)
      create(:report, show: show, kind: "agent", status: "failed", cost_usd: 5, taste_calls: 500)
      create(:report, show: show, kind: "snapshot", status: "done", taste_calls: 9)
      match = create(:sponsor_match, show: show, report: Report.agent.first)
      Pitch.create!(sponsor_match: match, status: "done", cost_usd: 0.02)

      inputs = described_class.check.inputs
      expect(inputs).to have_attributes(agent_llm_usd: BigDecimal("0.8"), agent_calls: 45, snapshot_calls: 30,
                                        pitch_llm_usd: described_class::PITCH_ESTIMATE_USD)
    end
  end

  describe "the go-live check" do
    it "isn't ready while the Qloo cost per call is blank, and shows no Qloo cost or margin" do
      check = described_class.check
      expect(check).not_to be_ready
      expect(check.blockers).to eq([ "the Qloo cost per call isn't set" ])
      expect(row("pro_monthly")).to have_attributes(qloo_usd: nil, margin: nil)
    end

    it "is ready when the cost is set and every paid price keeps 60% or more at its caps" do
      AppSettings.set(:qloo_cost_per_call_usd, "0.001")
      expect(described_class.check).to be_ready
    end

    it "names each paid price under 60% at its caps" do
      AppSettings.set(:qloo_cost_per_call_usd, "0.01")
      check = described_class.check

      expect(check).not_to be_ready
      # Shown rounded down, so a margin just under the bar never reads as 60%.
      expect(check.blockers).to contain_exactly("Creator yearly keeps 59% at its caps, under 60%",
                                                "Pro monthly keeps 57% at its caps, under 60%",
                                                "Pro yearly keeps 49% at its caps, under 60%",
                                                "Sprint keeps 57% at its caps, under 60%")
    end

    it "reads the cost per call as typed in admin, blank meaning unset" do
      AppSettings.set(:qloo_cost_per_call_usd, "0.0025")
      expect(described_class.cost_per_call).to eq(BigDecimal("0.0025"))
      AppSettings.set(:qloo_cost_per_call_usd, nil)
      expect(described_class.cost_per_call).to be_nil
      AppSettings.set(:qloo_cost_per_call_usd, "-1")
      expect(described_class.cost_per_call).to be_nil
    end
  end
end
