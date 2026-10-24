module Research
  module Tools
    class FindSponsorCandidates < Base
      TIERS = { easy_yes: "E", realistic: "R", long_shot: "L" }.freeze

      description "Finds and ranks sponsor candidates for a seed set (the saved seeds when no ids are given) and the " \
                  "2–3 brand categories you pick for this show (e.g. Finance, Productivity, Food & Beverage). Adds brands " \
                  "already sponsoring similar podcasts, scores fit 0–100 and tiers each brand. Returns refs (b1, b2…) " \
                  "to use in explain_matches and save_sponsor_matches."
      arguments({ categories: string_array("Brand categories to search, best first", max: SponsorCandidates::MAX_CATEGORIES),
                  entity_ids: string_array("Seed entity ids; leave empty to use the saved seeds"),
                  tag_ids: string_array("Seed tag ids; leave empty to use the saved seeds") },
                required: %i[categories])

      def execute(categories: [], entity_ids: [], tag_ids: [])
        entity_ids, tag_ids, ignored = seed_ids(entity_ids, tag_ids)
        return "#{ignored_note(ignored)}#{NO_SEEDS}" if entity_ids.empty? && tag_ids.empty?

        scored = SponsorCandidates.find(toolkit, seed_entity_ids: entity_ids, seed_tag_ids: tag_ids,
                                                 categories: strings(categories), scan_limit: scan_limit)
        if scored.empty?
          return "#{ignored_note(ignored)}No brands came back for those seeds — try different seeds or fewer category filters."
        end

        toolkit.add_candidates(scored)
        "#{ignored_note(ignored)}#{digest(scored)}"
      end

      private

      def scan_limit = Entitlements.for(toolkit.user).scan_limit

      # The best brands that fit in the reply, one line per brand category (categories ordered by their best
      # brand), e.g. "Finance: b2 Ramp 79E [5 sponsor reads, latest Shipping Soon], b10 Wealthfront 65E". Only
      # the brands listed are marked shown, so only they can be explained or saved; the rest are just counted.
      def digest(scored)
        count = scored.size.downto(1).find { |n| grouped(scored.first(n), hidden: scored.size - n).length < LIMIT - 1 } || 1
        toolkit.show_candidates(scored.first(count).map { |s| s.candidate.entity.id })
        grouped(scored.first(count), hidden: scored.size - count)
      end

      def grouped(shown, hidden:)
        lines = [ "Ranked #{shown.size + hidden} brands by category. Each: ref name fit(0–100)+tier " \
                  "(E easy yes, R realistic, L long shot) [evidence]." ]
        shown.group_by { |s| brand_category(s.candidate.entity) || "Other" }
             .each { |category, list| lines << "#{category}: #{list.map { |s| entry(s, category) }.join(', ')}" }
        lines << "#{hidden} lower-fit brands not shown." if hidden.positive?
        lines.join("\n")
      end

      def entry(scored, category)
        brand = scored.candidate.entity
        evidence = [ proven(scored.candidate.proven_evidence), shared(brand, category) ].compact
        "#{ref(scored)} #{brand.name} #{scored.fit_score}#{TIERS.fetch(scored.tier, '?')}" \
          "#{" [#{evidence.join('; ')}]" if evidence.any?}"
      end

      def proven(evidence)
        count = Matching::Evidence.count(evidence)
        return nil unless count.positive?

        show = Matching::Evidence.value(Matching::Evidence.items(evidence).first, :show)
        "#{count} sponsor #{'read'.pluralize(count)}, latest #{Untrusted.wrap(show)}"
      end

      # Audience tags the brand shares (R27), beyond its own category.
      def shared(brand, category)
        names = toolkit.shared_audience_tags(brand).map(&:name).uniq - [ category ]
        "shares #{names.first(2).join(', ')}" if names.any?
      end

      def ref(scored) = toolkit.brand_ref(scored.candidate.entity.id)
    end
  end
end
