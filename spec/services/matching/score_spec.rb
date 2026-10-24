require "rails_helper"

RSpec.describe Matching::Score do
  let(:now) { Time.zone.local(2026, 10, 24, 12) }

  def entity(popularity: 0.5, name: "Brand")
    Taste::Entity.new(id: name, name: name, type: "brand", popularity: popularity, affinity: nil,
                      image_url: nil, description: nil, website: nil, tags: [], properties: {})
  end

  def candidate(popularity: 0.5, affinity: 1.0, evidence: [ { show: "S", episode_title: "E", published_at: now - 1.day } ],
                shared: 10, category: true, name: "Brand")
    Matching::Candidate.new(entity: entity(popularity: popularity, name: name), affinity: affinity,
                            proven_evidence: evidence, shared_tag_count: shared, category_match: category)
  end

  def score_of(cands, downloads:)
    described_class.call(cands, downloads: downloads, now: now)
  end

  it "scores a perfect candidate 100 and tiers it easy_yes" do
    scored = score_of([ candidate ], downloads: 10_000).first
    expect(scored).to be_a(Matching::Scored)
    expect(scored.fit_score).to eq(100)
    expect(scored.tier).to eq(:easy_yes)
  end

  it "penalizes popular brands for small shows" do
    big = score_of([ candidate(popularity: 0.95) ], downloads: 10_000).first
    small = score_of([ candidate(popularity: 0.95) ], downloads: 1_000).first
    expect(big.fit_score - small.fit_score).to eq(13)
    expect(small.tier).to eq(:long_shot)
  end

  it "treats nil downloads as a small show" do
    big = score_of([ candidate(popularity: 0.95) ], downloads: 10_000).first
    nil_dl = score_of([ candidate(popularity: 0.95) ], downloads: nil).first
    expect(big.fit_score - nil_dl.fit_score).to eq(13)
  end

  it "gives full proven weight within 90 days and half when older" do
    recent = candidate(evidence: [ { show: "S", episode_title: "E", published_at: now - 89.days } ])
    old = candidate(evidence: [ { show: "S", episode_title: "E", published_at: now - 91.days } ])
    none = candidate(evidence: [])
    expect(score_of([ recent ], downloads: 10_000).first.fit_score).to eq(100)
    expect(score_of([ old ], downloads: 10_000).first.fit_score).to eq(90)
    expect(score_of([ none ], downloads: 10_000).first.fit_score).to eq(80)
  end

  it "normalizes affinity and shared tags against the max in the call" do
    a = candidate(affinity: 0.5, shared: 5, name: "A")
    b = candidate(affinity: 1.0, shared: 10, name: "B")
    scores = score_of([ a, b ], downloads: 10_000).to_h { |s| [ s.candidate.entity.name, s.fit_score ] }
    expect(scores["B"]).to eq(100)
    expect(scores["A"]).to eq(65)
  end

  it "handles nil and zero affinity and zero shared tags" do
    c = candidate(affinity: nil, shared: 0, evidence: [], category: false)
    expect(score_of([ c ], downloads: 10_000).first.fit_score).to eq(0)
  end

  it "clamps to 0 after the penalty" do
    c = candidate(popularity: 1.0, affinity: 0, shared: 0, evidence: [], category: false)
    expect(score_of([ c ], downloads: 100).first.fit_score).to eq(0)
  end

  it "sorts descending by score, ties broken by higher affinity" do
    low = candidate(affinity: 0.2, name: "low", shared: 0, evidence: [], category: false)
    # same score via different mix: affinity-heavy vs category-heavy is not equal, so craft equal scores
    x = candidate(affinity: 1.0, shared: 0, evidence: [], category: false, name: "x")
    y = candidate(affinity: 0.5, shared: 0, evidence: [], category: true, name: "y")
    result = score_of([ low, y, x ], downloads: 10_000)
    expect(result.map { |s| s.candidate.entity.name }).to eq(%w[x y low])
  end

  it "breaks exact score ties by higher affinity" do
    p_ = candidate(affinity: 1.0, shared: 0, evidence: [], category: false, name: "p")
    q = candidate(affinity: 0.5, shared: 5, category: false, name: "q") # 27.5 + 20 + 7.5
    r = candidate(affinity: 0.0, shared: 10, evidence: [], category: false, name: "r")
    result = score_of([ q, r, p_ ], downloads: 10_000)
    expect(result.map { |s| [ s.candidate.entity.name, s.fit_score ] }).to eq([ [ "p", 55 ], [ "q", 55 ], [ "r", 15 ] ])
  end
end

RSpec.describe Matching::Tier do
  it "maps popularity to tiers" do
    expect(described_class.for(0.9)).to eq(:long_shot)
    expect(described_class.for(0.89)).to eq(:realistic)
    expect(described_class.for(0.6)).to eq(:realistic)
    expect(described_class.for(0.59)).to eq(:easy_yes)
    expect(described_class.for(nil)).to eq(:realistic)
  end
end
