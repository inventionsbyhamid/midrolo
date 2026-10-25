module Research
  module Tools
    class ExplainMatches < Base
      MAX_BRANDS = 30
      TAGS_SHOWN = 4

      description "For up to #{MAX_BRANDS} candidate refs (best first): the taste tags each brand shares with this " \
                  "audience (its own Qloo tags that the audience's taste tags also have). Cite these tags in your reasons, " \
                  "or leave a reason empty to get a short one written from them."
      arguments({ brand_ids: string_array("Candidate refs (b1, b2…) or brand ids", max: MAX_BRANDS) }, required: %i[brand_ids])

      def execute(brand_ids: [])
        return NO_CANDIDATES if toolkit.scored.empty?

        keys = strings(brand_ids).first(MAX_BRANDS)
        unknown = keys.reject { |key| toolkit.resolve_brand(key) }
        ids = keys.filter_map { |key| toolkit.resolve_brand(key) }.uniq
        fresh = ids - toolkit.explanations.keys
        if fresh.any?
          toolkit.add_explanations(MatchExplainer.call(toolkit, brand_ids: fresh, seed_entity_ids: toolkit.seed_entity_ids))
        end
        digest(ids, unknown)
      end

      private

      def digest(ids, unknown)
        shared, none = ids.partition { |id| toolkit.explanations[id].present? }
        lines = []
        if shared.any?
          lines << "Shared tastes:"
          shared.each { |id| lines << "#{toolkit.brand_ref(id)} #{brand_name(id)}: #{toolkit.explanations[id].map(&:name).uniq.first(TAGS_SHOWN).join(', ')}" }
        end
        if none.any?
          lines << "No shared tastes found: #{none.map { |id| toolkit.brand_ref(id) }.join(', ')}. Cite proven evidence, " \
                   "or leave their reason empty for a short one."
        end
        lines << "Unknown refs ignored: #{unknown.join(', ')}." if unknown.any?
        lines.join("\n").presence || "Nothing to explain."
      end

      def brand_name(id) = toolkit.scored.fetch(id).candidate.entity.name
    end
  end
end
