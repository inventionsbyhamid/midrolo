require "rails_helper"

RSpec.describe Research::MatchExplainer do
  let(:taste) { Taste::Providers::Fake.new }
  let(:report) { create(:report) }
  let(:toolkit) { Research::Toolkit.new(report, taste: taste) }
  let(:seed_ids) { [ "fake:podcast:dollar-dispatch", "fake:podcast:shipping-soon" ] }
  let(:brands) { taste.recommend(type: :brand, entity_ids: seed_ids, take: 35) }
  let(:brand_ids) { brands.map(&:id) }

  before do
    toolkit.remember(brands)
    toolkit.audience_tags = taste.find_tags(query: "finance") + taste.find_tags(query: "productivity")
  end

  def explain(ids = brand_ids)
    described_class.call(toolkit, brand_ids: ids, seed_entity_ids: seed_ids)
  end

  def overlap(id) = toolkit.shared_audience_tags(toolkit.entity(id))

  describe "by default (R105: no compares)" do
    it "explains every brand from the tags it shares with the audience, without a Qloo call" do
      allow(taste).to receive(:compare)
      result = explain

      expect(described_class::MAX_COMPARES).to eq(0)
      expect(taste).not_to have_received(:compare)
      expect(result.keys).to eq(brand_ids)
      expect(result).to eq(brand_ids.to_h { |id| [ id, overlap(id) ] })
      expect(result.values.count(&:any?)).to be_positive
      expect(report.reload.taste_calls).to eq(0)
      expect(brand_ids.none? { |id| toolkit.compared?(id) }).to be(true)
    end

    it "logs one step with a short summary" do
      explain(brand_ids.first(3))
      step = report.agent_steps.last
      expect(step).to have_attributes(tool: "explain_matches", status: "ok")
      expect(step.label).to eq("Finding the tastes your audience shares with each brand…")
      expect(step.output_summary).to match(/\AExplained 3 brands, \d with shared tastes\z/)
    end

    it "returns an empty hash without a step when there is nothing to explain" do
      expect(explain([])).to eq({})
      expect(report.agent_steps).to be_empty
    end
  end

  context "when config/research.yml allows compares" do
    before { stub_const("#{described_class}::MAX_COMPARES", 5) }

    it "compares the first brands, keeps the shared tags and marks them compared, and explains the rest from the overlap" do
      allow(taste).to receive(:compare).and_call_original
      result = explain([ brand_ids.first ] + brand_ids.first(8))

      expect(taste).to have_received(:compare).exactly(5).times
      expect(taste).to have_received(:compare).with(a_entity_ids: seed_ids, b_entity_ids: [ brand_ids.first ], take: 10)
      expect(result.keys).to eq(brand_ids.first(8))
      expect(brand_ids.first(5).map { |id| toolkit.compared?(id) }).to all(be(true))
      expect(result.slice(*brand_ids.drop(5).first(3))).to eq(brand_ids.drop(5).first(3).to_h { |id| [ id, overlap(id) ] })
      expect(report.reload.taste_calls).to eq(5)
    end

    it "falls back to the overlap when compare comes back empty, as a podcast against a brand does (R105)" do
      allow(taste).to receive(:compare).and_return([])
      result = explain(brand_ids.first(2))

      expect(result).to eq(brand_ids.first(2).to_h { |id| [ id, overlap(id) ] })
      expect(brand_ids.first(2).none? { |id| toolkit.compared?(id) }).to be(true)
    end

    it "stops comparing once the run's research budget is spent" do
      toolkit = Research::Toolkit.new(report, taste: taste, max_taste_calls: 2)
      toolkit.remember(brands)
      allow(taste).to receive(:compare).and_call_original

      described_class.call(toolkit, brand_ids: brand_ids.first(5), seed_entity_ids: seed_ids)
      expect(taste).to have_received(:compare).twice
      expect(report.agent_steps.last).to have_attributes(status: "warning")
      expect(report.agent_steps.last.output_summary).to include("Skipped to stay within research budget")
    end

    it "warns, and explains from the overlap, when the profile has no entity seeds to compare (Review Focus #1)" do
      allow(taste).to receive(:compare)
      result = described_class.call(toolkit, brand_ids: brand_ids.first(3), seed_entity_ids: [])

      expect(taste).not_to have_received(:compare)
      expect(result.keys).to eq(brand_ids.first(3))
      expect(report.agent_steps.last).to have_attributes(tool: "explain_matches", status: "warning")
      expect(report.agent_steps.last.output_summary).to include("Your profile is built from topics, so reasons use shared tags")
    end

    it "skips a brand whose compare fails with a warning" do
      failing = brand_ids.second
      allow(taste).to receive(:compare).and_wrap_original do |original, **kw|
        raise Taste::Unavailable, "503" if kw[:b_entity_ids] == [ failing ]

        original.call(**kw)
      end

      explain(brand_ids.first(3))
      expect(toolkit.compared?(failing)).to be(false)
      expect(report.agent_steps.last.status).to eq("warning")
    end

    it "gives up comparing after three failures in a row" do
      allow(taste).to receive(:compare).and_raise(Taste::RateLimited, "429")

      expect(explain(brand_ids.first(10)).keys).to eq(brand_ids.first(10))
      expect(taste).to have_received(:compare).exactly(3).times
      expect(report.agent_steps.last.output_summary).to include("Stopped after 3 failed comparisons")
    end

    it "lets auth errors propagate" do
      allow(taste).to receive(:compare).and_raise(Taste::AuthError, "401")
      expect { explain(brand_ids.first(2)) }.to raise_error(Taste::AuthError)
    end
  end
end
