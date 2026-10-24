require "rails_helper"

RSpec.describe Research::MatchExplainer do
  let(:taste) { Taste::Providers::Fake.new }
  let(:report) { create(:report) }
  let(:toolkit) { Research::Toolkit.new(report, taste: taste) }
  let(:seed_ids) { [ "fake:podcast:dollar-dispatch", "fake:podcast:shipping-soon" ] }
  let(:brand_ids) { taste.recommend(type: :brand, entity_ids: seed_ids, take: 35).map(&:id) }

  def explain(ids = brand_ids)
    described_class.call(toolkit, brand_ids: ids, seed_entity_ids: seed_ids)
  end

  it "compares the seeds with each brand and returns its shared tags" do
    allow(taste).to receive(:compare).and_call_original
    result = explain(brand_ids.first(2))

    expect(result.keys).to eq(brand_ids.first(2))
    expect(result.values).to all(all(be_a(Taste::Tag)))
    expect(result.values.map(&:size)).to all(be_between(1, 10))
    expect(taste).to have_received(:compare).with(a_entity_ids: seed_ids, b_entity_ids: [ brand_ids.first ], take: 10)
  end

  it "stops at 30 brands and ignores duplicates" do
    allow(taste).to receive(:compare).and_call_original
    result = explain([ brand_ids.first ] + brand_ids)

    expect(result.keys).to eq(brand_ids.first(30))
    expect(taste).to have_received(:compare).exactly(30).times
  end

  it "logs one step with a short summary" do
    explain(brand_ids.first(3))
    step = report.agent_steps.last
    expect(step).to have_attributes(tool: "explain_matches", status: "ok")
    expect(step.label).to eq("Finding the tastes your audience shares with each brand…")
    expect(step.output_summary).to match(/\AExplained 3 brands/)
    expect(report.reload.taste_calls).to eq(3)
  end

  it "skips a brand whose compare fails with a warning" do
    failing = brand_ids.second
    allow(taste).to receive(:compare).and_wrap_original do |original, **kw|
      raise Taste::Unavailable, "503" if kw[:b_entity_ids] == [ failing ]

      original.call(**kw)
    end

    result = explain(brand_ids.first(3))
    expect(result.keys).to eq([ brand_ids.first, brand_ids.third ])
    expect(report.agent_steps.last.status).to eq("warning")
  end

  it "gives up after three failures in a row" do
    allow(taste).to receive(:compare).and_raise(Taste::RateLimited, "429")

    expect(explain(brand_ids.first(10))).to eq({})
    expect(taste).to have_received(:compare).exactly(3).times
    expect(report.agent_steps.last.output_summary).to include("Stopped after 3 failed comparisons")
  end

  it "lets auth errors propagate" do
    allow(taste).to receive(:compare).and_raise(Taste::AuthError, "401")
    expect { explain(brand_ids.first(2)) }.to raise_error(Taste::AuthError)
  end

  it "returns an empty hash without calls when there is nothing to explain" do
    expect(explain([])).to eq({})
    expect(report.agent_steps).to be_empty
  end
end
