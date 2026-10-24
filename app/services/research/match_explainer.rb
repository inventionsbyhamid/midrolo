module Research
  # Explains matches: for the top brands (R31: 12, to keep a run's Qloo calls down), the taste tags its fans
  # share with the show's entity seeds, from Qloo compare. Returns {brand_id => [Taste::Tag]}; brands past
  # the cap get their reasons from the R27 shared tags instead.
  #
  # A failing comparison skips that brand with a step warning; three failures in a row, or a spent research
  # budget, end the step early. Auth errors propagate. Compare needs entity seeds: a tag-only profile (a
  # show not on Qloo, seeded from topics) logs a warning step and returns {}.
  class MatchExplainer
    MAX_COMPARES = 12
    TAKE = 10
    MAX_FAILURES_IN_A_ROW = 3
    LABEL = "Finding the tastes your audience shares with each brand…".freeze
    TAG_ONLY_WARNING = "Your profile is built from topics, so reasons use shared tags".freeze

    def self.call(toolkit, brand_ids:, seed_entity_ids:) = new(toolkit, brand_ids, seed_entity_ids).call

    def initialize(toolkit, brand_ids, seed_entity_ids)
      @toolkit = toolkit
      @brand_ids = Array(brand_ids).map(&:to_s).reject(&:blank?).uniq.first(MAX_COMPARES)
      @seed_ids = Array(seed_entity_ids).map(&:to_s).uniq
    end

    def call
      return {} if @brand_ids.empty?
      return tag_only_profile if @seed_ids.empty?

      @toolkit.log.step("explain_matches", LABEL, input: "#{@brand_ids.size} brands") do |step|
        explained = compare_each(step)
        step.output_summary = summary(explained)
        explained
      end
    end

    private

    def tag_only_profile
      @toolkit.log.step("explain_matches", LABEL, input: "#{@brand_ids.size} brands") { |step| step.warn!(TAG_ONLY_WARNING) }
      {}
    end

    def compare_each(step)
      explained = {}
      failures = 0
      @brand_ids.each do |brand_id|
        if step.budget_spent?
          step.warn!(StepLogger::BUDGET_WARNING)
          break
        end

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
