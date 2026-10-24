require "csv"

module Pipeline
  # The pipeline as a spreadsheet. Brand names, categories and websites come from third-party taste data, and notes
  # from the podcaster, so any text a spreadsheet would run as a formula (=, +, -, @, or a leading tab or carriage
  # return) is prefixed with an apostrophe.
  class Csv
    HEADERS = [ "Show", "Brand", "Status", "Fit score", "Tier", "Category", "Website", "Follow-up date", "Notes",
                "Why it fits" ].freeze
    FORMULA_START = /\A[=+\-@\t\r]/

    def self.generate(matches) = new(matches).generate

    def initialize(matches)
      @matches = matches
    end

    def generate
      CSV.generate do |csv|
        csv << HEADERS
        @matches.each { |match| csv << row(match).map { |value| neutralize(value) } }
      end
    end

    private

    def row(match)
      [ match.show.title, match.name, match.status.humanize, match.fit_score, tier_label(match.tier), match.category,
        match.website, match.follow_up_on&.iso8601, match.notes, match.reason ]
    end

    def tier_label(tier) = ReportsHelper::TIERS.dig(tier.to_s, 0) || tier.to_s.humanize.presence

    def neutralize(value)
      value.is_a?(String) && value.match?(FORMULA_START) ? "'#{value}" : value
    end
  end
end
