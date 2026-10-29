require "rails_helper"

RSpec.describe FitSearch::Scoring do
  def score(**overrides)
    described_class.call(**{ affinity: nil, category_match: false, proof: [], price_fit: "ask", trust: nil, claimed: false }.merge(overrides))
  end

  it "weighs taste 50, proof 25, price 15 and trust 10, for 100 at most" do
    best = score(affinity: 1.0, proof: [ { "relation" => "you", "episodes" => 3 } ], price_fit: "within", trust: "verified")

    expect(best).to have_attributes(total: 100, taste: 50, proof: 25, price: 15, trust: 10)
    expect(best.parts).to eq("taste" => 50, "proof" => 25, "price" => 15, "trust" => 10)
  end

  it "scores fixed facts the same way every time" do
    facts = { affinity: 0.73, category_match: true, proof: [ { "relation" => "competitor", "episodes" => 2 } ],
              price_fit: "stretch", trust: "provided", claimed: true }

    expect(score(**facts)).to have_attributes(total: 37 + 16 + 8 + 6, taste: 37, proof: 16, price: 8, trust: 6)
    expect(score(**facts)).to eq(score(**facts))
  end

  it "gives a show in the brand's categories without a Qloo score a small taste share, and others none" do
    expect(score(category_match: true).taste).to eq(10)
    expect(score(category_match: false).taste).to eq(0)
    expect(score(affinity: 0.0, category_match: true).taste).to eq(0) # a real score, even 0, wins
  end

  it "counts at most 3 episodes a brand, weighs each relation, and caps proof at 25" do
    rows = ->(relation, episodes) { [ { "relation" => relation, "episodes" => episodes } ] }

    expect(score(proof: rows.call("competitor", 1)).proof).to eq(8)
    expect(score(proof: rows.call("competitor", 9)).proof).to eq(24)
    expect(score(proof: rows.call("complementary", 2)).proof).to eq(10)
    expect(score(proof: rows.call("category", 1)).proof).to eq(4)
    expect(score(proof: rows.call("stranger", 3)).proof).to eq(0)
    expect(score(proof: rows.call("competitor", 3) + rows.call("category", 3)).proof).to eq(25)
  end

  it "gives claimed shows without numbers a little trust, and unclaimed ones none" do
    expect(score(trust: nil, claimed: true).trust).to eq(3)
    expect(score(trust: nil, claimed: false).trust).to eq(0)
    expect(score(trust: "public").trust).to eq(4)
    expect(score(trust: "feed").trust).to eq(1)
  end

  it "keeps the total between 0 and 100" do
    expect(score.total).to eq(5) # no taste, no proof, no rate card yet
    expect(score(affinity: 7.0).taste).to eq(50)
  end

  describe ".price_fit" do
    it "compares the lowest rate per episode with the budget per episode" do
      expect(described_class.price_fit(price_cents: nil, budget_cents: 50_000)).to eq("ask")
      expect(described_class.price_fit(price_cents: 40_000, budget_cents: nil)).to eq("no_budget")
      expect(described_class.price_fit(price_cents: 40_000, budget_cents: 0)).to eq("no_budget")
      expect(described_class.price_fit(price_cents: 50_000, budget_cents: 50_000)).to eq("within")
      expect(described_class.price_fit(price_cents: 62_500, budget_cents: 50_000)).to eq("stretch")
      expect(described_class.price_fit(price_cents: 62_501, budget_cents: 50_000)).to eq("over")
    end
  end
end
