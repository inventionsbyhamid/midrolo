class FitSearch
  # A fit result's score, 0 to 100, from four parts (build spec L6): taste 50, proof 25, price fit 15, trust 10.
  # Deterministic: the same facts always give the same score.
  #
  #   taste  Qloo's affinity between the brand's audience and the show (0 to 1) times 50. A show in the brand's
  #          categories that Qloo has no score for counts as CATEGORY_ONLY_AFFINITY; any other show without one, 0.
  #   proof  for each brand like this one that sponsored the show: its relation's weight times its episodes (at most
  #          3 count), 25 at most. The brand itself weighs most, then a competitor, a complementary brand, a brand in
  #          the same category.
  #   price  the show's lowest rate per episode against the brand's budget per episode (PRICE_POINTS).
  #   trust  how far its downloads number can be trusted (TRUST_POINTS); a claimed show without numbers gets
  #          CLAIMED_POINTS.
  #
  # The rank puts bookable shows first (tier, below), then orders each tier by this score.
  module Scoring
    WEIGHTS = { taste: 50, proof: 25, price: 15, trust: 10 }.freeze
    CATEGORY_ONLY_AFFINITY = 0.2
    PROOF_WEIGHTS = { "you" => 10, "competitor" => 8, "complementary" => 5, "category" => 4 }.freeze
    PROOF_EPISODES_COUNTED = 3
    # within: at or under budget; stretch: up to 25% over; over: more; ask: no rate card yet; no_budget: a rate card,
    # but the brand gave no budget.
    PRICE_POINTS = { "within" => 15, "stretch" => 8, "over" => 0, "ask" => 5, "no_budget" => 10 }.freeze
    STRETCH = 1.25
    TRUST_POINTS = { "verified" => 10, "provided" => 6, "public" => 4, "feed" => 1 }.freeze
    CLAIMED_POINTS = 3

    Score = Data.define(:total, :taste, :proof, :price, :trust) do
      def parts = { "taste" => taste, "proof" => proof, "price" => price, "trust" => trust }
    end

    module_function

    # affinity: 0 to 1, or nil; category_match: whether the show is in the brand's categories; proof: rows with
    # "relation" and "episodes"; price_fit: a PRICE_POINTS key; trust: a StatReading trust level or nil.
    def call(affinity:, category_match:, proof:, price_fit:, trust:, claimed:)
      parts = { taste: taste_points(affinity, category_match), proof: proof_points(proof),
                price: PRICE_POINTS.fetch(price_fit.to_s, 0), trust: trust_points(trust, claimed) }
      Score.new(total: parts.values.sum.clamp(0, 100), **parts)
    end

    def taste_points(affinity, category_match)
      value = affinity.nil? ? (category_match ? CATEGORY_ONLY_AFFINITY : 0.0) : affinity.to_f.clamp(0.0, 1.0)
      (value * WEIGHTS[:taste]).round
    end

    def proof_points(rows)
      total = Array(rows).sum do |row|
        PROOF_WEIGHTS.fetch(row["relation"].to_s, 0) * row["episodes"].to_i.clamp(0, PROOF_EPISODES_COUNTED)
      end
      [ total, WEIGHTS[:proof] ].min
    end

    def trust_points(trust, claimed)
      TRUST_POINTS[trust.to_s] || (claimed ? CLAIMED_POINTS : 0)
    end

    # Whether a brand can book the show today, best first (review BR-6). The fit score says how well the audience
    # matches; the tier says whether anyone will answer. Results rank by tier, then by score, so a show that is
    # claimed, open to sponsors, priced within the budget and still publishing comes before a better taste match
    # nobody can book yet.
    #
    #   ready      claimed, open to sponsors, a rate card within the budget (or no budget given), still publishing
    #   open       claimed and open to sponsors, but over the budget or without a rate card yet
    #   claimed    claimed by the show, not open to sponsors
    #   unclaimed  hasn't joined Midrolo; a request waits until it claims its page
    #   dormant    no new episode in months, whatever else is true
    TIERS = %w[ready open claimed unclaimed dormant].freeze
    READY_PRICES = %w[within no_budget].freeze

    def tier(claimed:, open:, price_fit:, dormant:)
      return "dormant" if dormant
      return "unclaimed" unless claimed
      return "claimed" unless open

      READY_PRICES.include?(price_fit.to_s) ? "ready" : "open"
    end

    # The rank order: tier first, then the score, then Qloo's affinity, then the podcast's id for ties.
    def rank_key(tier:, total:, affinity:, id:)
      [ TIERS.index(tier.to_s) || TIERS.size, -total.to_i, -(affinity || 0).to_f, id.to_i ]
    end

    # A word for the score (review BR-5): taste scores from Qloo rarely pass 60, so the number alone reads as low.
    FIT_WORDS = [ [ 55, "Strong fit" ], [ 35, "Good fit" ], [ 0, "Some fit" ] ].freeze

    def fit_word(total) = FIT_WORDS.find { |floor, _| total.to_i >= floor }.last

    # The show's lowest rate per episode against the brand's budget per episode, both in cents.
    def price_fit(price_cents:, budget_cents:)
      return "ask" if price_cents.nil?
      return "no_budget" if budget_cents.to_i <= 0
      return "within" if price_cents <= budget_cents
      return "stretch" if price_cents <= budget_cents * STRETCH

      "over"
    end
  end
end
