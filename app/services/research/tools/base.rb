module Research
  module Tools
    # Shared plumbing: a tool is built with the run's toolkit, is named for the model after its class
    # ("ReadShowFeed" => "read_show_feed"), and always answers with a String under 1,500 characters.
    # Qloo trouble the model can work around (rate limits, outages, bad requests) comes back as a message;
    # auth errors propagate, since the runner pauses runs on them, and so does our own call guard's refusal (R92):
    # retrying can't help, so the run fails as busy rather than spending LLM turns. Once the run reaches its hard
    # ceiling of Qloo calls (R130), a tool whose work is Qloo calls (calls_qloo!) refuses up front, and a call the guard
    # refuses mid-tool ends the tool the same way: with QLOO_BUDGET_SPENT, so the model saves what it has.
    class Base < RubyLLM::Tool
      LIMIT = 1500
      IGNORED_NOTE_LIMIT = 300
      NO_SEEDS = "Save taste seeds first (save_taste_seeds), then call this again.".freeze
      NO_CANDIDATES = "Find sponsor candidates first (find_sponsor_candidates), then call this again.".freeze
      ARRAY_OF_STRINGS = { type: "array", items: { type: "string" } }.freeze
      QLOO_BUDGET_SPENT = "This report's Qloo budget is used up. Save what you have.".freeze

      def self.tool_name = name.demodulize.underscore

      # Marks a tool whose work is live Qloo calls: it refuses once the run's hard ceiling is reached (R130).
      def self.calls_qloo! = (@calls_qloo = true)
      def self.calls_qloo? = @calls_qloo == true

      # The arguments as a plain JSON Schema object.
      def self.arguments(properties = {}, required: [])
        parameters({ type: "object", properties: properties, required: required.map(&:to_s), additionalProperties: false })
      end

      def self.string_array(description, max: nil)
        ARRAY_OF_STRINGS.merge(description: description, maxItems: max).compact
      end

      def initialize(toolkit)
        super()
        @toolkit = toolkit
      end

      # RubyLLM answers invalid arguments with {error: "..."}; everything reaches the model as a short String.
      def call(**)
        return QLOO_BUDGET_SPENT if self.class.calls_qloo? && toolkit.taste_ceiling_reached?

        result = super
        compact(result.is_a?(Hash) ? result[:error] || result.to_json : result)
      rescue Taste::AuthError, Taste::MissingCredentials, Taste::CallCapReached
        raise
      rescue Taste::RunBudgetSpent
        QLOO_BUDGET_SPENT
      rescue Taste::BadRequest, Taste::Unsupported, Taste::NotFound => e
        # The same request gets the same answer (R110), so the model shouldn't spend a turn and a call on it.
        compact("Qloo error: #{StepLogger.describe(e)} Nothing changed. Don't retry this request; carry on with what you have.")
      rescue Taste::Error => e
        compact("Qloo error: #{StepLogger.describe(e)} Nothing changed. Retry once, or carry on with what you have.")
      end

      private

      attr_reader :toolkit

      delegate :report, :show, :log, to: :toolkit, private: true

      def compact(text) = text.to_s.truncate(LIMIT - 1, omission: "…")

      def strings(list) = Array(list).map { |v| v.to_s.strip }.reject(&:blank?).uniq

      # Seed ids the model passed, keeping only those a tool returned this run; the saved seeds when it
      # passed none. Returns [entity_ids, tag_ids, ignored].
      def seed_ids(entity_ids, tag_ids)
        entity_ids = strings(entity_ids)
        tag_ids = strings(tag_ids)
        return [ toolkit.seed_entity_ids, toolkit.seed_tag_ids, [] ] if entity_ids.empty? && tag_ids.empty?

        known_entities, unknown_entities = entity_ids.partition { |id| toolkit.entity(id) }
        known_tags, unknown_tags = tag_ids.partition { |id| toolkit.tag(id) }
        [ known_entities, known_tags, unknown_entities + unknown_tags ]
      end

      def ignored_note(ignored)
        "Ignored ids no tool returned: #{ignored.join(', ').truncate(IGNORED_NOTE_LIMIT)}.\n" if ignored.any?
      end

      # A value from a Hash the model sent, by symbol or string key.
      def value(hash, key)
        return nil unless hash.respond_to?(:key?)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end

      def brand_category(entity)
        Array(entity.tags).find { |t| t.id.to_s.start_with?(SponsorCandidates::BRAND_TAG_PREFIX) }&.name
      end
    end
  end
end
