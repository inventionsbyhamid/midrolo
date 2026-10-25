module Research
  # Explains matches: the taste tags each brand shares with this audience. Returns {brand_id => [Taste::Tag]} for every
  # brand id given.
  #
  # By default every brand is explained from the overlap of its own Qloo tags with the audience's taste tags already
  # fetched (R27, the template path), with no Qloo call: a live probe showed Qloo's compare finds no shared tags between a
  # podcast and a brand (R105). Compare still runs for the first MAX_COMPARES brands of a report when
  # config/research.yml allows any (0 by default) and the profile has entity seeds; those brands are marked compared on
  # the toolkit, and one whose compare comes back empty falls back to the overlap.
  #
  # A failing comparison skips that brand with a step warning; three failures in a row, or a spent research budget, stop
  # the comparing. Auth errors propagate.
  class MatchExplainer
    MAX_COMPARES = Research.caps.fetch(:match_explainer_compares)
    TAKE = 10
    MAX_FAILURES_IN_A_ROW = 3
    LABEL = "Finding the tastes your audience shares with each brand…".freeze
    TAG_ONLY_WARNING = "Your profile is built from topics, so reasons use shared tags".freeze

    def self.call(toolkit, brand_ids:, seed_entity_ids:) = new(toolkit, brand_ids, seed_entity_ids).call

    def initialize(toolkit, brand_ids, seed_entity_ids)
      @toolkit = toolkit
      @brand_ids = Array(brand_ids).map(&:to_s).reject(&:blank?).uniq
      @seed_ids = Array(seed_entity_ids).map(&:to_s).uniq
    end

    def call
      return {} if @brand_ids.empty?

      @toolkit.log.step("explain_matches", LABEL, input: "#{@brand_ids.size} brands") do |step|
        compared = compare_some(step)
        explained = @brand_ids.to_h { |id| [ id, compared[id].presence || overlap(id) ] }
        step.output_summary = summary(explained)
        explained
      end
    end

    private

    # The tags the brand shares with the audience, by id or by name (Toolkit#shared_audience_tags).
    def overlap(brand_id)
      brand = @toolkit.scored[brand_id]&.candidate&.entity || @toolkit.entity(brand_id)
      brand ? @toolkit.shared_audience_tags(brand) : []
    end

    # {brand_id => [Taste::Tag]} for the brands Qloo compared within the report's MAX_COMPARES.
    def compare_some(step)
      room = MAX_COMPARES - @toolkit.compared_count
      return {} unless room.positive?

      if @seed_ids.empty?
        step.warn!(TAG_ONLY_WARNING)
        return {}
      end

      compare_each(step, @brand_ids.reject { |id| @toolkit.compared?(id) }.first(room))
    end

    def compare_each(step, brand_ids)
      compared = {}
      failures = 0
      brand_ids.each do |brand_id|
        if step.budget_spent?
          step.warn!(StepLogger::BUDGET_WARNING)
          break
        end

        tags = step.optional("A brand comparison") do
          @toolkit.taste.compare(a_entity_ids: @seed_ids, b_entity_ids: [ brand_id ], take: TAKE)
        end
        if tags
          failures = 0
          next if tags.empty?

          @toolkit.mark_compared(brand_id)
          compared[brand_id] = tags
        elsif (failures += 1) >= MAX_FAILURES_IN_A_ROW
          step.warn!("Stopped after #{MAX_FAILURES_IN_A_ROW} failed comparisons in a row")
          break
        end
      end
      compared
    end

    def summary(explained)
      shared = explained.values.count(&:any?)
      "Explained #{explained.size} #{'brand'.pluralize(explained.size)}, #{shared} with shared tastes"
    end
  end
end
