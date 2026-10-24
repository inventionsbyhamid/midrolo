module Research
  module Tools
    # The provenance check (spec §6): only brands from this run's candidate set are saved, each with the
    # scored data and evidence the tools produced. The model supplies just the pick and its reason.
    class SaveSponsorMatches < Base
      MAX_MATCHES = SponsorCandidates::MAX_RESULTS
      REASON_LIMIT = 200

      description "Saves the sponsor matches: 20–40 candidate refs from find_sponsor_candidates, each with a " \
                  "one-sentence reason (under #{REASON_LIMIT} characters) citing shared taste tags or proven-sponsor " \
                  "evidence from the tools. Brands not in the candidate list are rejected. Each call replaces the saved " \
                  "list, so resend the full list when fixing rejections."
      arguments({ matches: { type: "array", maxItems: MAX_MATCHES,
                             items: { type: "object", additionalProperties: false, required: %w[brand_id reason],
                                      properties: { brand_id: { type: "string", description: "Candidate ref (b1…) or brand id" },
                                                    reason: { type: "string", maxLength: REASON_LIMIT } } } } },
                required: %i[matches])

      # The scripted snapshot saves matches without reasons.
      def initialize(toolkit, require_reasons: true)
        super(toolkit)
        @require_reasons = require_reasons
      end

      def execute(matches: [])
        return NO_CANDIDATES if toolkit.scored.empty?

        picks = Array(matches)
        log.step("save_sponsor_matches", "Saving your sponsor matches…", input: "#{picks.size} picks") do |step|
          accepted, rejected = sort(picks)
          persist(accepted)
          step.warn!("Rejected #{rejected.size}") if rejected.any?
          step.output_summary = "Saved #{accepted.size} #{'match'.pluralize(accepted.size)}"
          message(accepted.size, rejected)
        end
      end

      private

      # Returns [{brand_id => reason} for valid picks, ["key (why)"] for the rest].
      def sort(picks)
        accepted = {}
        rejected = []
        picks.each do |pick|
          key = value(pick, :brand_id).to_s.strip
          reason = value(pick, :reason).to_s.squish.presence
          id = toolkit.resolve_brand(key)
          problem = if id.nil? then "not in the candidate list"
          elsif reason && reason.length > REASON_LIMIT then "reason over #{REASON_LIMIT} characters"
          elsif reason.nil? && @require_reasons then "no reason"
          end
          next rejected << "#{key.presence || '(no brand_id)'} (#{problem})" if problem

          accepted[id] ||= reason
        end
        [ accepted.first(MAX_MATCHES).to_h, rejected ]
      end

      # Replaces the run's matches, positioned by fit.
      def persist(accepted)
        scored = accepted.keys.map { |id| toolkit.scored.fetch(id) }.sort_by { |s| [ -s.fit_score, -s.candidate.affinity.to_f ] }
        SponsorMatch.transaction do
          SponsorMatch.where(report_id: report.id).delete_all
          scored.each.with_index(1) do |s, position|
            report.sponsor_matches.create!(attributes(s, accepted[s.candidate.entity.id], position))
          end
        end
        report.save_section!(:matches)
      end

      def attributes(scored, reason, position)
        brand = scored.candidate.entity
        { show_id: report.show_id, brand_entity_id: brand.id, name: brand.name, image_url: brand.image_url,
          website: brand.website, category: brand_category(brand), reason: reason, affinity: scored.candidate.affinity,
          popularity: brand.popularity, fit_score: scored.fit_score, tier: scored.tier.to_s, position: position,
          evidence: { "shared_tags" => shared_tags(brand), "proven" => proven(scored.candidate.proven_evidence) } }
      end

      # Compare tags from explain_matches, else the tags the brand shares with the audience (R27).
      def shared_tags(brand) = Templates.shared_tags(toolkit, brand)

      def proven(evidence)
        items = Matching::Evidence.items(evidence).map do |item|
          { "show" => Matching::Evidence.value(item, :show), "episode_title" => Matching::Evidence.value(item, :episode_title),
            "published_at" => Matching::Evidence.published_at(item)&.iso8601 }
        end
        { "items" => items, "count" => Matching::Evidence.count(evidence) }
      end

      def message(saved, rejected)
        text = "Saved #{saved} #{'match'.pluralize(saved)}"
        return "#{text}." if rejected.empty?

        "#{text}; rejected #{rejected.size}: #{rejected.join(', ')}. Each call replaces the saved list: resend the full list to fix these."
      end
    end
  end
end
