require "rails_helper"

RSpec.describe AdminHelper do
  let(:stats) do
    instance_double(
      Admin::Stats,
      users: { today: 1, month: 4 }, pitches: { today: 0, month: 3 },
      waitlist: { today: { notify: 2, plans: 0 }, month: { notify: 5, plans: 1 } },
      average_agent_cost: { today: nil, month: BigDecimal("0.456") },
      reports: { today: { %w[agent done] => 1 }, month: { %w[agent done] => 2, %w[snapshot needs_input] => 1 } },
      spend: { today: { "promo" => BigDecimal("0.4") }, month: { "promo" => BigDecimal("0.5"), "paid" => BigDecimal("1.25") } }
    )
  end

  describe "#admin_total_groups" do
    subject(:groups) { helper.admin_total_groups(stats) }

    it "lists the headline totals, with a dash for no average cost" do
      expect(groups[nil]).to eq([
        [ "New users", { today: 1, month: 4 } ],
        [ "Pitches", { today: 0, month: 3 } ],
        [ "Waitlist: notify me", { today: 2, month: 5 } ],
        [ "Waitlist: plans", { today: 0, month: 1 } ],
        [ "Average cost per done full report", { today: "None", month: "$0.46" } ]
      ])
    end

    it "has a row for each kind and status seen this month, in the model's order" do
      expect(groups["Reports"]).to eq([
        [ "Snapshot · needs input", { today: 0, month: 1 } ],
        [ "Agent · done", { today: 1, month: 2 } ]
      ])
    end

    it "has a row for every spend bucket, then the total" do
      expect(groups["Spend"].map(&:first)).to eq(%w[Dev Promo Judge Paid Sample Total])
      expect(groups["Spend"].to_h.slice("Promo", "Paid", "Total"))
        .to eq("Promo" => { today: "$0.40", month: "$0.50" }, "Paid" => { today: "$0.00", month: "$1.25" },
               "Total" => { today: "$0.40", month: "$1.75" })
    end
  end

  describe "#admin_budget_meter" do
    def meter(usage) = Nokogiri::HTML.fragment(helper.admin_budget_meter("Promo", usage)).at_css("[role='meter']")

    it "shows spent of ceiling" do
      node = meter(spent: BigDecimal("1.25"), ceiling: BigDecimal("5"))
      expect(node["aria-valuenow"]).to eq("25")
      expect(node["aria-valuetext"]).to eq("$1.25 of $5.00")
    end

    it "reads full when there is spend against a zero ceiling, and empty when there is none" do
      expect(meter(spent: BigDecimal("0.1"), ceiling: BigDecimal("0"))["aria-valuenow"]).to eq("100")
      expect(meter(spent: BigDecimal("0"), ceiling: BigDecimal("0"))["aria-valuenow"]).to eq("0")
    end
  end
end
