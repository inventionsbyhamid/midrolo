module ShareImages
  # A sample report's share image: the show's title labelled as a sample (not affiliated with the show), how many brand
  # matches the report found and the audience's top taste tags. No artwork: the show isn't the podcaster's own.
  class SampleCard < Card
    # report comes from Samples.find!.
    def initialize(report)
      @report = report
      @show = report.show
    end

    private

    def key_parts = [ "sample", version_of(@report), version_of(@show), version_of(@show.podcast), "matches-#{match_count}" ]

    def fields
      { label: "Sample report", title: @show.title, subline: "Not affiliated with the show.",
        stat: match_stat, tags: taste_tags, seed: @show.id }
    end

    # One COUNT when the matches aren't loaded (the image route doesn't load them).
    def match_count = @match_count ||= @report.sponsor_matches.size

    def match_stat
      count = match_count
      return unless count.positive?

      [ count.to_s, count == 1 ? "brand match, with its reason" : "brand matches, each with its reason" ]
    end

    def taste_tags
      tags = @report.audience.is_a?(Hash) ? Array(@report.audience["tags"]) : []
      Report.distinct_tastes(tags.select { |tag| tag.is_a?(Hash) && tag["name"].present? }).map { |tag| tag["name"] }
    end
  end
end
