require "rails_helper"

RSpec.describe Research::AudienceProfile do
  let(:taste) { Taste::Providers::Fake.new }
  let(:report) { create(:report) }
  let(:toolkit) { Research::Toolkit.new(report, taste: taste) }
  let(:seed_ids) { [ "fake:podcast:the-founder-s-ledger" ] }
  let(:tag_ids) { [ "urn:tag:genre:media:business" ] }

  def build(country: "US")
    described_class.build(toolkit, seed_entity_ids: seed_ids, seed_tag_ids: tag_ids, country: country)
  end

  it "saves the audience, demographics and heatmap sections" do
    result = build
    report.reload

    audience = report.audience
    expect(audience.keys).to match_array(%w[brands artists tv_shows podcasts tags])
    expect(audience["brands"].size).to eq(20)
    expect(audience["brands"].first.keys).to match_array(%w[id name image_url affinity popularity website])
    expect(audience["artists"].size).to eq(10)
    expect(audience["tv_shows"].size).to eq(10)
    expect(audience["podcasts"].size).to eq(10)
    expect(audience["tags"].size).to eq(15)
    expect(audience["tags"].first.keys).to match_array(%w[id name score])

    expect(report.demographics.keys).to match_array(%w[age gender])
    expect(report.demographics["age"]).to be_present

    expect(report.heatmap).to include("location" => "US", "country" => "US")
    expect(report.heatmap["points"]).to be_present
    expect(report.heatmap["points"].first.keys).to match_array(%w[lat lng affinity label])

    expect(result[:thin]).to be(false)
    expect(report.agent_steps.pluck(:status)).to all(eq("ok"))
  end

  it "returns a compact digest that names brands with their ids" do
    digest = build[:digest]
    brand = report.reload.audience["brands"].first

    expect(digest.length).to be < 1500
    expect(digest).to include("#{brand['name']} (#{brand['id']})")
    expect(digest).to include(report.audience["podcasts"].first["name"])
    expect(digest).not_to include("fake:artist:")
  end

  it "keeps the audience tags on the toolkit and remembers every entity it saw" do
    build
    audience = report.reload.audience
    expect(toolkit.audience_tags.map(&:id)).to eq(audience["tags"].pluck("id"))
    ids = %w[brands artists tv_shows podcasts].flat_map { |k| audience[k].pluck("id") }
    expect(toolkit.seen_entity_ids).to include(*ids)
  end

  it "flags a thin profile when fewer than 8 brands come back" do
    allow(taste).to receive(:recommend).and_wrap_original do |original, **kw|
      list = original.call(**kw)
      kw[:type] == :brand ? list.first(5) : list
    end

    result = build
    expect(result[:thin]).to be(true)
    expect(result[:digest]).to include("Thin profile")
    expect(report.reload.audience["brands"].size).to eq(5)
  end

  it "says so explicitly when no brands come back" do
    allow(taste).to receive(:recommend).and_wrap_original do |original, **kw|
      kw[:type] == :brand ? [] : original.call(**kw)
    end
    expect(build[:digest]).to include("No brands came back")
  end

  it "falls back to the first 6 metros when the country heatmap is empty" do
    locations = []
    allow(taste).to receive(:heatmap).and_wrap_original do |original, **kw|
      locations << kw[:location]
      kw[:location] == "United States" ? [] : original.call(**kw)
    end

    build
    heatmap = report.reload.heatmap
    metros = Rails.application.config_for(:geo)[:US].first(6)
    expect(locations).to eq([ "United States", *metros ])
    expect(heatmap["location"]).to eq("metros")
    expect(heatmap["points"].size).to be > 0
    expect(heatmap["points"].size).to be <= 200
    expect(heatmap["points"].map { |p| p["affinity"] }).to eq(heatmap["points"].map { |p| p["affinity"] }.sort.reverse)
  end

  it "skips a failing metro with a warning" do
    allow(taste).to receive(:heatmap).and_wrap_original do |original, **kw|
      next [] if kw[:location] == "United States"
      raise Taste::Unavailable, "down" if kw[:location] == "Chicago"

      original.call(**kw)
    end

    build
    expect(report.reload.heatmap["points"]).to be_present
    map_step = report.agent_steps.find_by(tool: "heatmap")
    expect(map_step.status).to eq("warning")
    expect(map_step.output_summary).to include("Chicago skipped")
  end

  it "skips optional parts on a Qloo outage and still saves every section" do
    allow(taste).to receive(:recommend).and_wrap_original do |original, **kw|
      raise Taste::RateLimited, "429" if kw[:type] == :artist

      original.call(**kw)
    end
    allow(taste).to receive(:demographics).and_raise(Taste::Unavailable, "503")

    result = build
    report.reload
    expect(report.audience["artists"]).to eq([])
    expect(report.audience["brands"].size).to eq(20)
    expect(report.demographics).to eq("age" => {}, "gender" => {})
    expect(result[:thin]).to be(false)
    expect(report.agent_steps.pluck(:status)).to include("warning")
  end

  it "keeps the core brand call but skips optional parts once the research budget is spent" do
    kit = Research::Toolkit.new(report, taste: taste, max_taste_calls: 1)
    result = described_class.build(kit, seed_entity_ids: seed_ids, seed_tag_ids: tag_ids, country: "US")
    report.reload

    expect(report.audience["brands"].size).to eq(20)
    expect(report.audience.values_at("artists", "tv_shows", "podcasts", "tags")).to all(eq([]))
    expect(report.demographics).to eq("age" => {}, "gender" => {})
    expect(report.heatmap["points"]).to eq([])
    expect(result[:thin]).to be(false)
    expect(report.agent_steps.pluck(:status)).to all(eq("warning"))
    expect(report.agent_steps.pluck(:output_summary)).to all(include("Skipped to stay within research budget"))
    expect(report.taste_calls).to eq(1)
  end

  it "lets a failing brand recommendation propagate" do
    allow(taste).to receive(:recommend).and_raise(Taste::Unavailable, "503")
    expect { build }.to raise_error(Taste::Unavailable)
    expect(report.reload.audience).to be_nil
  end

  it "counts the taste calls it makes" do
    build
    expect(report.reload.taste_calls).to eq(7)
  end
end
