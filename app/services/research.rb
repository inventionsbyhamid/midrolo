# The research engine: deterministic services (seeds, profile, candidates, proven sponsors), the agent's tools,
# and the runners that drive them (Research::Run picks one).
module Research
  # Fewer than 2 taste seeds: the report asks the podcaster for comparable shows (Review Focus #1).
  class NeedsInput < StandardError; end
  # The agent hit its tool-call or time cap.
  class LimitReached < StandardError; end
  # The agent stopped without saving any sponsor matches.
  class IncompleteRun < StandardError; end
end
