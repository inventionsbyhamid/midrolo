module Research
  # The research agent's tools. They are coarse on purpose: each bundles several Qloo or directory calls in
  # Ruby and answers with a compact summary, so a report takes 6–10 agent turns, not 20+ (spec §6).
  module Tools
    def self.classes
      [ ReadShowFeed, FindOnQloo, SaveTasteSeeds, BuildAudienceProfile, FindSponsorCandidates, ExplainMatches,
        SaveSponsorMatches, SaveSummary ]
    end

    # One instance of each tool, sharing the run's toolkit.
    def self.all(toolkit) = classes.map { |tool| tool.new(toolkit) }
  end
end
