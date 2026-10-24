require "rails_helper"

RSpec.describe Research::SponsorCandidates do
  let(:taste) { Taste::Providers::Fake.new }
  let(:directory) { Podcasts::Directories::Fake.new }
  let(:show) { create(:show, title: "Totally Unknown Indie Show", downloads_per_episode: 1200, hints: { comparable_shows: [ "The Founder's Ledger" ] }) }
  let(:report) { create(:report, show: show) }
  let(:toolkit) { Research::Toolkit.new(report, taste: taste, directory: directory) }
  let(:seed_ids) { [ "fake:podcast:dollar-dispatch" ] }
  let(:tag_ids) { [ "urn:tag:genre:media:business" ] }

  def find(categories: [ "Finance" ], scan_limit: 3)
    described_class.find(toolkit, seed_entity_ids: seed_ids, seed_tag_ids: tag_ids, categories: categories, scan_limit: scan_limit)
  end

  def only_first_brands(count)
    allow(taste).to receive(:recommend).and_wrap_original do |original, **kw|
      list = original.call(**kw)
      kw[:type] == :brand ? list.first(count) : list
    end
  end

  it "returns at most 50 scored brands with no duplicate ids, all remembered" do
    result = find(categories: [ "Finance", "Productivity", "Technology" ])

    expect(result).to all(be_a(Matching::Scored))
    expect(result.size).to eq(50)
    ids = result.map { |s| s.candidate.entity.id }
    expect(ids.uniq.size).to eq(ids.size)
    expect(toolkit.seen_entity_ids).to include(*ids)
    expect(result.map(&:fit_score)).to eq(result.map(&:fit_score).sort.reverse)
    expect(result.map { |s| s.candidate.entity.type }).to all(eq(:brand))
  end

  it "runs the broad pass with a popularity cap and a filtered pass per category" do
    calls = []
    allow(taste).to receive(:recommend).and_wrap_original do |original, **kw|
      calls << { type: kw[:type], filter_tags: kw[:filter_tags] || [], popularity_max: kw[:popularity_max], take: kw[:take] }
      original.call(**kw)
    end

    find(categories: [ "Finance", "Pet Supplies" ])
    brand_calls = calls.select { |c| c[:type] == :brand }
    expect(brand_calls).to eq([
      { type: :brand, filter_tags: [], popularity_max: 0.97, take: 50 },
      { type: :brand, filter_tags: [ "urn:tag:genre:brand:finance" ], popularity_max: nil, take: 20 },
      { type: :brand, filter_tags: [ "urn:tag:genre:brand:pet_supplies" ], popularity_max: nil, take: 20 }
    ])
  end

  it "marks brands in a chosen category" do
    result = find(categories: [ "Finance" ])
    finance, other = result.partition { |s| s.candidate.entity.tags.map(&:id).include?("urn:tag:genre:brand:finance") }

    expect(finance).not_to be_empty
    expect(finance.map { |s| s.candidate.category_match }).to all(be(true))
    expect(other.map { |s| s.candidate.category_match }).to all(be(false))
  end

  it "merges proven sponsors from similar shows with symbol-keyed, dated evidence" do
    only_first_brands(3)
    result = find(categories: [])
    mercury = result.find { |s| s.candidate.entity.name == "Mercury" }

    expect(mercury).to be_present
    evidence = mercury.candidate.proven_evidence
    expect(evidence.first.keys).to eq(%i[show episode_title published_at])
    expect(evidence.first[:show]).to eq("The Founder's Ledger")
    expect(evidence.first[:published_at]).to be_a(Time)
    expect(result.map { |s| s.candidate.entity.id }).to include(*taste.recommend(type: :brand, entity_ids: seed_ids, tag_ids: tag_ids, popularity_max: 0.97, take: 3).map(&:id))
  end

  it "scans the listed comparable shows first, then the audience's podcasts, up to scan_limit" do
    report.update!(audience: { "podcasts" => [ { "name" => "Index Fund Mornings" }, { "name" => "Shipping Soon" } ] })
    allow(Research::ProvenSponsorScan).to receive(:new).and_call_original

    find(scan_limit: 2)
    expect(Research::ProvenSponsorScan).to have_received(:new)
      .with(toolkit, podcast_names: [ "The Founder's Ledger", "Index Fund Mornings", "Shipping Soon" ], limit: 2)
  end

  it "counts tags shared with the audience by id, falling back to the tag name" do
    toolkit.audience_tags = [
      Taste::Tag.new(id: "urn:tag:genre:brand:finance", name: "Finance", type: "urn:tag:genre:brand", score: 0.9),
      Taste::Tag.new(id: "urn:tag:other:productivity", name: "Productivity", type: "urn:tag:other", score: 0.5)
    ]
    result = find(categories: [ "Finance", "Productivity" ])
    by_category = result.group_by { |s| s.candidate.entity.tags.first.id.split(":").last }

    expect(by_category["finance"].map { |s| s.candidate.shared_tag_count }).to all(eq(1))
    expect(by_category["productivity"].map { |s| s.candidate.shared_tag_count }).to all(eq(1))
    others = result.reject { |s| %w[finance productivity].include?(s.candidate.entity.tags.first.id.split(":").last) }
    expect(others.map { |s| s.candidate.shared_tag_count }).to all(eq(0))
  end

  it "reads the saved audience tags when the toolkit has none" do
    report.update!(audience: { "tags" => [ { "id" => "urn:tag:genre:brand:finance", "name" => "Finance", "score" => 0.9 } ] })
    result = find(categories: [ "Finance" ])
    finance = result.select { |s| s.candidate.category_match }
    expect(finance.map { |s| s.candidate.shared_tag_count }).to all(eq(1))
  end

  it "scores with the show's downloads" do
    allow(Matching::Score).to receive(:call).and_call_original
    find
    expect(Matching::Score).to have_received(:call).with(anything, downloads: 1200)
  end

  it "scores the merged set with affinity_for on the seeds" do
    allow(taste).to receive(:affinity_for).and_call_original
    result = find
    expect(taste).to have_received(:affinity_for).with(hash_including(entity_ids: seed_ids, tag_ids: tag_ids, type: :brand)).once
    expect(result.map { |s| s.candidate.affinity }).to all(be_a(Float))
  end

  it "skips a failing category pass with a warning" do
    allow(taste).to receive(:recommend).and_wrap_original do |original, **kw|
      raise Taste::Unavailable, "503" if kw[:filter_tags].present?

      original.call(**kw)
    end

    expect(find(categories: [ "Finance" ])).not_to be_empty
    expect(report.agent_steps.pluck(:status)).to include("warning")
  end

  it "lets the broad recommendation's errors propagate" do
    allow(taste).to receive(:recommend).and_raise(Taste::AuthError, "401")
    expect { find }.to raise_error(Taste::AuthError)
  end

  it "lets affinity_for errors propagate" do
    allow(taste).to receive(:affinity_for).and_raise(Taste::Unavailable, "503")
    expect { find }.to raise_error(Taste::Unavailable)
    expect(report.agent_steps.last.status).to eq("error")
  end
end
