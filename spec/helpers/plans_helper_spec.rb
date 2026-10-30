require "rails_helper"

# The account page's usage bars (accounts/_plan). The request spec checks them against real plans; these pin the
# words and the bar's arithmetic at the edges.
RSpec.describe PlansHelper do
  def usage(used: 0, in_flight: 0, limit: 4, period: "month")
    PlansHelper::Usage.new(kind: :agent, label: "Full reports", plan_name: "Creator", used: used, in_flight: in_flight,
                           limit: limit, period: period)
  end

  describe "#usage_count" do
    it "bolds the numbers and adds the period and work in progress" do
      html = Nokogiri::HTML5.fragment(helper.usage_count(usage(used: 1, in_flight: 2, period: "billing period")))

      expect(html.text).to eq("1 of 4 used this billing period, 2 in progress")
      expect(html.at_css("strong").text).to eq("1 of 4")
    end

    it "leaves the period out when the plan counts in total" do
      expect(Nokogiri::HTML5.fragment(helper.usage_count(usage(period: nil))).text).to eq("0 of 4 used")
    end

    it "says Unlimited, or that the plan leaves the kind out" do
      expect(helper.usage_count(usage(limit: Float::INFINITY))).to eq("<strong>Unlimited</strong>")
      expect(helper.usage_count(usage(limit: 0))).to eq("Not on the Creator plan")
    end
  end

  describe "#usage_segments" do
    it "gives each unit a segment up to the cap, done work first, then work in progress" do
      expect(helper.usage_segments(usage(used: 1, in_flight: 1, limit: 4))).to eq(%i[on busy off off])
      expect(helper.usage_segments(usage(used: 3, limit: 3))).to eq(%i[on on on])
      expect(helper.usage_segments(usage(used: 5, limit: 3))).to eq(%i[on on on]) # past a lowered limit
      expect(helper.usage_segments(usage(limit: 20)).size).to eq(20)
    end

    it "scales a larger limit to the cap, lighting a segment for any work and never all short of the limit" do
      segments = ->(used, in_flight = 0) { helper.usage_segments(usage(used: used, in_flight: in_flight, limit: 60)).tally }

      expect(segments.call(0)).to eq(off: 20)
      expect(segments.call(1)).to eq(on: 1, off: 19)
      expect(segments.call(30, 6)).to eq(on: 10, busy: 2, off: 8)
      expect(segments.call(59)).to eq(on: 19, off: 1)
      expect(segments.call(60)).to eq(on: 20)
    end
  end

  describe "#plan_usage" do
    # The double has no used or in_flight, so asking for either would fail.
    it "counts nothing for a kind the plan leaves out or doesn't limit" do
      plan = instance_double(Entitlements::Plan, name: "Judge access", period_name: "month", counted_in_total?: false)
      allow(plan).to receive(:limit) { |kind| { pitch: Float::INFINITY, agent: 0 }.fetch(kind) }

      expect(helper.plan_usage(plan, :pitch)).to have_attributes(unlimited?: true, metered?: false, used: 0, in_flight: 0)
      expect(helper.plan_usage(plan, :agent)).to have_attributes(included?: false, metered?: false, used: 0)
    end
  end
end
