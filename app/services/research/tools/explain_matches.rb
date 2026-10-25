module Research
  module Tools
    class ExplainMatches < Base
      MAX_BRANDS = 30
      TAGS_SHOWN = 4

      description "For up to #{MAX_BRANDS} candidate refs (best first): the taste tags each brand's fans share with the " \
                  "show's seed entities, from Qloo. The first #{MatchExplainer::MAX_COMPARES} per report are compared. " \
                  "Cite these tags in your reasons."
      arguments({ brand_ids: string_array("Candidate refs (b1, b2…) or brand ids", max: MAX_BRANDS) }, required: %i[brand_ids])

      def execute(brand_ids: [])
        return NO_CANDIDATES if toolkit.scored.empty?

        keys = strings(brand_ids).first(MAX_BRANDS)
        unknown = keys.reject { |key| toolkit.resolve_brand(key) }
        ids = keys.filter_map { |key| toolkit.resolve_brand(key) }.uniq
        fresh = ids - toolkit.explanations.keys
        room = MatchExplainer::MAX_COMPARES - toolkit.explanations.size
        compare = fresh.first([ room, 0 ].max)
        if compare.any?
          toolkit.add_explanations(MatchExplainer.call(toolkit, brand_ids: compare, seed_entity_ids: toolkit.seed_entity_ids))
        end
        digest(ids, unknown)
      end

      private

      def digest(ids, unknown)
        explained, rest = ids.partition { |id| toolkit.explanations[id].present? }
        lines = []
        if toolkit.seed_entity_ids.empty?
          lines << "Your seeds are all tags, so Qloo can't compare brands. Cite the shared tags and proven evidence " \
                   "from find_sponsor_candidates instead."
        elsif explained.any?
          lines << "Shared tastes (Qloo compare):"
          explained.each { |id| lines << "#{toolkit.brand_ref(id)} #{brand_name(id)}: #{toolkit.explanations[id].map(&:name).uniq.first(TAGS_SHOWN).join(', ')}" }
        end
        if rest.any? && toolkit.seed_entity_ids.any?
          lines << "Not compared (#{MatchExplainer::MAX_COMPARES} per report, or no shared tastes found): " \
                   "#{rest.map { |id| toolkit.brand_ref(id) }.join(', ')}. Use their shared tags or proven evidence, or " \
                   "leave their reason empty for a short one from shared tags."
        end
        lines << "Unknown refs ignored: #{unknown.join(', ')}." if unknown.any?
        lines.join("\n").presence || "Nothing to explain."
      end

      def brand_name(id) = toolkit.scored.fetch(id).candidate.entity.name
    end
  end
end
