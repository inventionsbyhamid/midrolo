# The research engine: deterministic services (seeds, profile, candidates, proven sponsors), the agent's tools,
# and the runners that drive them (Research::Run picks one).
module Research
  # Fewer than 2 taste seeds: the report asks the podcaster for comparable shows (Review Focus #1).
  class NeedsInput < StandardError; end
  # The agent hit a cap: kind is :tool_calls or :time.
  class LimitReached < StandardError
    attr_reader :kind

    def initialize(kind = :time, message = nil)
      @kind = kind
      super(message || "#{kind} limit reached")
    end
  end
  # The agent stopped without saving any sponsor matches.
  class IncompleteRun < StandardError; end
end
