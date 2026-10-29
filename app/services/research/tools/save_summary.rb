module Research
  module Tools
    # The summary is the At a glance box at the top of the report (R99): 1 to 3 bullets of 20 words or fewer, one a
    # line. Dashes come out first (R100). Over the limits, the first 3 bullets are kept and a long one is cut to its
    # first sentence or at a word boundary (the last resort), and the result says so the model can reword and save
    # again. It waits for the sponsor matches it summarizes (R140): a model that skips ahead is sent back.
    class SaveSummary < Base
      MAX_BULLETS = Report::SUMMARY_POINTS
      BULLET_WORDS = Report::SUMMARY_POINT_WORDS
      BULLET_LENGTH = Report::SUMMARY_POINT_LENGTH
      # A brand ref as the tools write it ("b4"), inside a sentence.
      REF = /\bb\d+\b/
      # List marks and stray punctuation a model sometimes leads a bullet with (": ", "- ", "• ").
      LEADING_MARKS = /\A[\s:;,.*•-]+/
      NO_MATCHES ="Save sponsor matches first: build_audience_profile, find_sponsor_candidates, explain_matches, " \
                   "then save_sponsor_matches. Save the summary after that.".freeze

      description "Saves the summary the podcaster reads first, at the top of the report: 1 to #{MAX_BULLETS} bullets, " \
                  "each one plain, specific sentence of #{BULLET_WORDS} words or fewer. First, who the audience is, " \
                  "as a group. Then which sponsors to approach first and why. A third only for a caveat: for a proxy " \
                  "profile, say it was built from comparable shows and topics. Use only tool data and no numbers the " \
                  "tools didn't give."
      arguments({ bullets: { type: "array", minItems: 1, maxItems: MAX_BULLETS,
                             items: { type: "string", maxLength: BULLET_LENGTH,
                                      description: "One plain sentence, #{BULLET_WORDS} words or fewer" } } },
                required: %i[bullets])

      def execute(bullets: [])
        return NO_MATCHES unless report.sponsor_matches.exists?

        given = Array(bullets).map { |bullet| readable(Llm::PlainText.sanitize(bullet.to_s.squish)) }.compact_blank
        return "The summary is empty. Write 1 to #{MAX_BULLETS} bullets and save it again." if given.empty?

        unknown = given.join(" ").scan(REF).uniq
        if unknown.any?
          return "The summary names #{unknown.join(', ')}, which no tool showed you. Use brand names and save it again."
        end

        points = given.first(MAX_BULLETS).map { |bullet| Llm::PlainText.clip_words(bullet, BULLET_WORDS, max_chars: BULLET_LENGTH) }
        claims = NumericClaims.new(toolkit)
        unsupported = claims.unsupported(points.join("\n"), claims.for_summary)
        if unsupported.any?
          return "The summary cites numbers not in the data (#{unsupported.join(', ')}): rephrase without them and save it again."
        end

        log.step("save_summary", "Writing your summary…") do |step|
          report.save_section!(:summary, points.join("\n"))
          step.output_summary = "#{points.size} #{'bullet'.pluralize(points.size)}"
        end
        [ "Summary saved.", *notes(given, points) ].join(" ")
      end

      private

      # The reader gets brand names, never the tools' refs ("b4"), and no stray leading list mark (R146).
      def readable(bullet)
        named = bullet.gsub(REF) do |ref|
          id = toolkit.resolve_brand(ref)
          id ? toolkit.scored.fetch(id).candidate.entity.name : ref
        end
        named.sub(LEADING_MARKS, "")
      end

      def notes(given, points)
        shortened = points.each_index.select { |i| points[i] != given[i] }.map { |i| i + 1 }
        [
          ("Kept the first #{MAX_BULLETS} bullets." if given.size > MAX_BULLETS),
          if shortened.any?
            "Shortened #{'bullet'.pluralize(shortened.size)} #{Copy.and_list(shortened.map(&:to_s))} to #{BULLET_WORDS} words; " \
              "save again to reword #{shortened.one? ? 'it' : 'them'}."
          end
        ].compact
      end
    end
  end
end
