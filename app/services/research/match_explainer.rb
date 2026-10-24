module Research
  # Explains matches: for each brand (up to 30), the taste tags its fans share with the show's seeds,
  # from Qloo compare. Returns {brand_id => [Taste::Tag]}. A failing comparison skips that brand with a
  # step warning; three failures in a row end the step early. Auth errors propagate.
  class MatchExplainer
    MAX_BRANDS = 30
    TAKE = 10
    MAX_FAILURES_IN_A_ROW = 3

    def self.call(toolkit, brand_ids:, seed_entity_ids:) = new(toolkit, brand_ids, seed_entity_ids).call

    def initialize(toolkit, brand_ids, seed_entity_ids)
      @toolkit = toolkit
      @brand_ids = Array(brand_ids).map(&:to_s).reject(&:blank?).uniq.first(MAX_BRANDS)
      @seed_ids = Array(seed_entity_ids).map(&:to_s).uniq
    end

    def call
      return {} if @brand_ids.empty? || @seed_ids.empty?

      @toolkit.log.step("explain_matches", "Finding the tastes your audience shares with each brand…",
                        input: "#{@brand_ids.size} brands") do |step|
        explained = compare_each(step)
        step.output_summary = summary(explained)
        explained
      end
    end

    private

    def compare_each(step)
      explained = {}
      failures = 0
      @brand_ids.each do |brand_id|
        tags = step.optional("A brand comparison") do
          @toolkit.taste.compare(a_entity_ids: @seed_ids, b_entity_ids: [ brand_id ], take: TAKE)
        end
        if tags
          failures = 0
          explained[brand_id] = tags
        elsif (failures += 1) >= MAX_FAILURES_IN_A_ROW
          step.warn!("Stopped after #{MAX_FAILURES_IN_A_ROW} failed comparisons in a row")
          break
        end
      end
      explained
    end

    def summary(explained)
      return "No shared tastes found" if explained.empty?

      average = (explained.values.sum(&:size) / explained.size.to_f).round
      "Explained #{explained.size} #{'brand'.pluralize(explained.size)}, about #{average} shared tastes each"
    end
  end
end
