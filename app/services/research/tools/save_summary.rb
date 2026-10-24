module Research
  module Tools
    class SaveSummary < Base
      MAX_LENGTH = 600

      description "Saves the report summary: 2–4 plain sentences (under #{MAX_LENGTH} characters) on who the audience " \
                  "is and which sponsors to approach first, using only tool data and no numbers the tools didn't give. " \
                  "Say the profile is a proxy when it is."
      arguments({ summary: { type: "string", maxLength: MAX_LENGTH } }, required: %i[summary])

      def execute(summary: "")
        text = summary.to_s.strip
        return "The summary is empty. Write 2–4 sentences and save it again." if text.blank?
        return "The summary is #{text.length} characters; keep it under #{MAX_LENGTH} and save it again." if text.length > MAX_LENGTH

        claims = NumericClaims.new(toolkit)
        unsupported = claims.unsupported(text, claims.for_summary)
        if unsupported.any?
          return "The summary cites numbers not in the data (#{unsupported.join(', ')}) — rephrase without them and save it again."
        end

        log.step("save_summary", "Writing your summary…") do |step|
          report.save_section!(:summary, text)
          step.output_summary = "#{text.length} characters"
        end
        "Summary saved."
      end
    end
  end
end
