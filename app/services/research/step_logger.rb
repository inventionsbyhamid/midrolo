module Research
  # Records each unit of research work as an AgentStep the run's page shows live, and counts the uncached taste
  # requests made while it runs into run.taste_calls. A run is a podcaster's Report or a brand's FitSearch.
  #
  #   log.step("heatmap", "Mapping where your listeners live…") do |step|
  #     step.output_summary = "42 areas"
  #     step.warn!("Seattle skipped") # the step ends as warning instead of ok
  #   end
  #
  # An exception marks the step error (with a short, user-safe message) and is re-raised. Any other way out
  # of the block (normal end, return, break, throw) finishes it ok or warning.
  #
  # Research budget (R31): one logger serves one run. Once the run has made max_taste_calls uncached taste
  # requests, Step#optional stops calling out. Core calls aren't wrapped in optional, so they keep running until the
  # hard ceiling (R130): once the run has made hard_taste_calls, Taste::CallGuard refuses every further live request
  # inside a step with Taste::RunBudgetSpent, before it is made.
  class StepLogger
    # Qloo trouble a non-essential sub-call may skip, as if it came back empty: an outage, a rate limit, a request Qloo
    # couldn't use (400), a type the key can't use (403, R87) or nothing found (404). AuthError is never soft: the
    # runner pauses runs on it.
    SOFT_ERRORS = [ Taste::Unavailable, Taste::RateLimited, Taste::BadRequest, Taste::Unsupported, Taste::NotFound ].freeze
    BUDGET_WARNING = "Skipped to stay within research budget".freeze
    SUMMARY_LIMIT = 500
    INPUT_LIMIT = 300

    # What the block sees: set output_summary, call warn!, or wrap optional work in #optional.
    class Step
      attr_accessor :output_summary
      attr_reader :warnings

      def initialize(logger)
        @logger = logger
        @warnings = []
      end

      def warn!(message)
        @warnings << message.to_s
        nil
      end

      def warned? = @warnings.any?

      def budget_spent? = @logger.budget_spent?

      # Runs the block unless the run's budget is spent. On a Qloo outage or rate limit, records
      # "<what> skipped: …" and returns nil. A call the hard ceiling refuses is skipped as over budget.
      def optional(what)
        return warn!(BUDGET_WARNING) if budget_spent?

        yield
      rescue Taste::RunBudgetSpent
        warn!(BUDGET_WARNING)
      rescue *SOFT_ERRORS => e
        warn!("#{what} skipped: #{StepLogger.describe(e)}")
        nil
      end
    end

    # A short message that is safe to show users (never the raw vendor response).
    def self.describe(error)
      case error
      when Taste::AuthError then "Qloo rejected our API key."
      when Taste::CallCapReached then "Taste data is busy right now."
      when Taste::RunBudgetSpent then "This report's Qloo budget is used up."
      when Taste::RateLimited then "Qloo is rate limiting us."
      when Taste::Unavailable then "Qloo is unavailable right now."
      when Taste::BadRequest then "Qloo couldn't use that request."
      when Taste::Unsupported then "Qloo doesn't support that request."
      when Taste::NotFound then "Qloo has no results for that request."
      when Podcasts::Directory::Unavailable then "The podcast directory is unavailable right now."
      else "Something went wrong (#{error.class.name.demodulize})."
      end
    end

    # config/research.yml (R93, R130).
    def self.configured_max_taste_calls = Research.caps.fetch(:max_taste_calls)
    def self.configured_hard_taste_calls = Research.caps.fetch(:hard_taste_calls)

    attr_reader :run, :max_taste_calls, :hard_taste_calls

    # run: a Report or a FitSearch (anything with agent_steps and taste_calls).
    def initialize(run, max_taste_calls: self.class.configured_max_taste_calls,
                   hard_taste_calls: self.class.configured_hard_taste_calls)
      @run = run
      @max_taste_calls = max_taste_calls
      @hard_taste_calls = hard_taste_calls
      @uncached_calls = Concurrent::AtomicFixnum.new
      @counting_key = :"research_step_logger_#{object_id}_counting"
    end

    # Uncached taste requests made inside this run's steps so far.
    def uncached_calls = @uncached_calls.value

    def budget_spent? = uncached_calls >= max_taste_calls

    # The run may make no more live taste requests (R130).
    def hard_budget_spent? = uncached_calls >= hard_taste_calls

    def step(tool, label, input: nil)
      record = run.agent_steps.create!(position: next_position, tool: tool.to_s, label: label, status: "running",
                                          input_summary: input.to_s.truncate(INPUT_LIMIT).presence)
      handle = Step.new(self)
      started = monotonic
      failed = false
      begin
        counting_taste_calls { yield handle }
      rescue Exception => e # rubocop:disable Lint/RescueException -- marks the step, then always re-raises
        failed = true
        finish(record, handle, started, status: "error", message: self.class.describe(e))
        raise
      ensure
        finish(record, handle, started, status: handle.warned? ? "warning" : "ok") unless failed
      end
    end

    private

    def next_position
      run.agent_steps.maximum(:position).to_i + 1
    end

    # Only the outermost step on a thread subscribes, so nested steps don't double count. The flag is
    # thread-local, and events from other threads are ignored, so concurrent steps each count their own. The same
    # step holds the call guard to this run's hard ceiling.
    def counting_taste_calls(&block)
      return yield if Thread.current[@counting_key]

      Thread.current[@counting_key] = true
      calls = 0
      thread = Thread.current
      counter = lambda do |_name, _started, _finished, _id, payload|
        next unless Thread.current.equal?(thread) && !payload[:cached]

        calls += 1
        @uncached_calls.increment
      end
      begin
        Taste::CallGuard.run_ceiling(-> { hard_budget_spent? }) do
          ActiveSupport::Notifications.subscribed(counter, "request.taste", &block)
        end
      ensure
        Thread.current[@counting_key] = nil
        record_taste_calls(calls)
      end
    end

    # Runs inside an ensure: a failure here must never replace the step's own outcome or exception.
    def record_taste_calls(calls)
      run.increment!(:taste_calls, calls) if calls.positive?
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { run_type: run.class.name, run_id: run.id, taste_calls: calls })
    end

    def finish(record, handle, started, status:, message: nil)
      summary = [ message || handle.output_summary.presence, *handle.warnings.uniq ].compact.join(" · ")
      record.update!(status: status, output_summary: summary.truncate(SUMMARY_LIMIT).presence,
                     duration_ms: ((monotonic - started) * 1000).round)
    rescue StandardError => e
      raise unless status == "error" # never mask the original error with a logging failure

      Rails.logger.error("[StepLogger] could not record a failed step: #{e.class}: #{e.message}")
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
