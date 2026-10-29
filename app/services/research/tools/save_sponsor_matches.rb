module Research
  module Tools
    # The provenance check (spec §6): only brands from this run's candidate set that were shown to the model
    # are saved, each with the scored data and evidence the tools produced. The model supplies just the pick
    # and its reason, and a reason may cite only numbers found in that data (R38, NumericClaims).
    # A reason is one plain sentence of 25 words or fewer (R99): dashes come out first (R100), and a longer reason is
    # cut to its first sentence or at a word boundary (the last resort), and the result says which were cut. A brand Qloo
    # didn't compare (every brand by default, R93, R105) may come with an empty reason: it gets the simpler template
    # reason from its shared tags (Research::Templates), and the result says which.
    class SaveSponsorMatches < Base
      MAX_MATCHES = SponsorCandidates::MAX_RESULTS
      REASON_LIMIT = SponsorMatch::REASON_LENGTH
      REASON_WORDS = SponsorMatch::REASON_WORDS
      TARGET_MATCHES = 20

      description "Saves the sponsor matches: 20 to 40 candidate refs from find_sponsor_candidates, each with a reason: " \
                  "one plain, specific sentence of #{REASON_WORDS} words or fewer citing shared taste tags or " \
                  "proven-sponsor evidence from the tools, with no numbers the tools didn't give. Make each one about " \
                  "its brand: name its most specific shared taste (a broad one like Technology only when there's " \
                  "nothing narrower) and what the brand offers these listeners, and don't open two reasons the same " \
                  "way. Leave out the fit " \
                  "score and tier (the card shows them), and say a brand sponsors podcasts only when its candidate " \
                  "entry lists sponsor reads. An empty reason gets a " \
                  "short one written from the brand's shared tags. Brands not in the candidate " \
                  "list are rejected. Each call replaces the saved list, so resend the full list when fixing rejections."
      arguments({ matches: { type: "array", maxItems: MAX_MATCHES,
                             items: { type: "object", additionalProperties: false, required: %w[brand_id reason],
                                      properties: { brand_id: { type: "string", description: "Candidate ref (b1…) or brand id" },
                                                    reason: { type: "string", maxLength: REASON_LIMIT,
                                                              description: "One plain sentence, #{REASON_WORDS} words or fewer" } } } } },
                required: %i[matches])

      # The scripted snapshot saves matches without reasons.
      def initialize(toolkit, require_reasons: true)
        super(toolkit)
        @require_reasons = require_reasons
      end

      def execute(matches: [])
        return NO_CANDIDATES if toolkit.scored.empty?

        @shortened = []
        @templated = []
        picks = Array(matches)
        log.step("save_sponsor_matches", "Saving your sponsor matches…", input: "#{picks.size} picks") do |step|
          accepted, rejected = sort(picks)
          if accepted.any?
            persist(accepted)
          else
            step.warn!("Nothing accepted, so the earlier list was kept")
          end
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
          id = toolkit.resolve_brand(key)
          reason, shortened = fit_reason(value(pick, :reason))
          reason ||= template_reason(id)
          problem = problem_with(id, key, reason)
          next rejected << problem if problem

          # Counted only once the pick is saved, so a rejected pick is reported once, as rejected.
          @shortened << key if shortened && !accepted.key?(id)
          accepted[id] ||= reason
        end
        [ accepted.first(MAX_MATCHES).to_h, rejected ]
      end

      # [the reason without dashes, cut to one sentence of REASON_WORDS when longer, whether it was cut]; nil when blank.
      def fit_reason(text)
        reason = Llm::PlainText.sanitize(text.to_s.squish).presence
        return [ nil, false ] if reason.nil?

        fitted = Llm::PlainText.clip_words(reason, REASON_WORDS, max_chars: REASON_LIMIT)
        [ fitted, fitted != reason ]
      end

      # The template reason from shared tags, for a brand Qloo didn't compare (R93, R105); nil for the rest.
      def template_reason(id)
        return nil unless @require_reasons && id && !toolkit.compared?(id)

        @templated << toolkit.brand_ref(id)
        Templates.reason(toolkit, toolkit.scored.fetch(id))
      end

      def problem_with(id, key, reason)
        label = key.presence || "(no brand_id)"
        return "#{label} (not in the candidate list)" if id.nil?
        return "#{label} (no reason)" if reason.nil? && @require_reasons

        unsupported = reason ? claims.unsupported(reason, claims.for_match(toolkit.scored.fetch(id))) : []
        if unsupported.any?
          "reason for #{toolkit.brand_ref(id) || label} cites numbers not in the data (#{unsupported.join(', ')}): rephrase without them"
        end
      end

      def claims = @claims ||= NumericClaims.new(toolkit)

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
          website: brand.website, brand_description: brand_description(brand), category: brand_category(brand),
          reason: reason, affinity: scored.candidate.affinity,
          popularity: brand.popularity, fit_score: scored.fit_score, tier: scored.tier.to_s, position: position,
          evidence: { "shared_tags" => shared_tags(brand), "proven" => proven(scored.candidate.proven_evidence) } }
      end

      # Qloo's description of the brand, for the pitch writer (R52). Third-party text: never shown on a card.
      def brand_description(brand) = brand.description.to_s.squish.first(SponsorMatch::BRAND_DESCRIPTION_LIMIT).presence

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
        text += rejected.empty? ? "." : "; rejected #{rejected.size}: #{rejected.join('; ')}."
        if saved.zero?
          kept = report.sponsor_matches.count
          text += kept.positive? ? " Nothing changed: your earlier #{kept} #{'match'.pluralize(kept)} are still saved." : " Nothing was saved."
        elsif rejected.any?
          text += " Each call replaces the saved list: resend the full list to fix these."
        end
        if @templated.any?
          refs = @templated.uniq
          text += " Wrote #{refs.size} short #{'reason'.pluralize(refs.size)} from shared tags (#{refs.first(10).join(', ')}) " \
                  "for brands Qloo didn't compare."
        end
        if @shortened.any?
          text += " Shortened #{@shortened.size} #{'reason'.pluralize(@shortened.size)} to #{REASON_WORDS} words " \
                  "(#{@shortened.first(10).join(', ')}): keep each to one sentence of #{REASON_WORDS} words or fewer."
        end
        if saved.positive? && saved < TARGET_MATCHES && toolkit.shown_candidate_count >= TARGET_MATCHES
          text += " You saved #{saved}; consider saving at least #{TARGET_MATCHES}."
        end
        text
      end
    end
  end
end
