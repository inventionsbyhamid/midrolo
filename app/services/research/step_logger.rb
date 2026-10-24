module Research
  # Records each unit of research work as an AgentStep the report page shows live, and counts the taste
  # requests made while it runs into report.taste_calls.
  #
  #   log.step("heatmap", "Mapping where your listeners live…") do |step|
  #     step.output_summary = "42 areas"
  #     step.warn!("Seattle skipped") # the step ends as warning instead of ok
  #   end
  #
  # An exception marks the step error (with a short, user-safe message) and is re-raised.
  class StepLogger
    # Qloo trouble a non-essential sub-call may skip. AuthError is never soft: the runner pauses runs on it.
    SOFT_ERRORS = [ Taste::Unavailable, Taste::RateLimited ].freeze
    SUMMARY_LIMIT = 500
    INPUT_LIMIT = 300

    # What the block sees: set output_summary, call warn!, or wrap optional work in #optional.
    class Step
      attr_accessor :output_summary
      attr_reader :warnings

      def initialize
        @warnings = []
      end

      def warn!(message)
        @warnings << message.to_s
        nil
      end

      def warned? = @warnings.any?

      # Runs the block. On a Qloo outage or rate limit, records "<what> skipped: …" and returns nil.
      def optional(what)
        yield
      rescue *SOFT_ERRORS => e
        warn!("#{what} skipped: #{StepLogger.describe(e)}")
        nil
      end
    end

    # A short message that is safe to show users (never the raw vendor response).
    def self.describe(error)
      case error
      when Taste::AuthError then "Qloo rejected our API key."
      when Taste::RateLimited then "Qloo is rate limiting us."
      when Taste::Unavailable then "Qloo is unavailable right now."
      when Podcasts::Directory::Unavailable then "The podcast directory is unavailable right now."
      else "Something went wrong (#{error.class.name.demodulize})."
      end
    end

    attr_reader :report

    def initialize(report)
      @report = report
      @counting = false
    end

    def step(tool, label, input: nil)
      record = report.agent_steps.create!(position: next_position, tool: tool.to_s, label: label, status: "running",
                                          input_summary: input.to_s.truncate(INPUT_LIMIT).presence)
      handle = Step.new
      started = monotonic
      result = counting_taste_calls { yield handle }
      finish(record, handle, started, status: handle.warned? ? "warning" : "ok")
      result
    rescue Exception => e # rubocop:disable Lint/RescueException -- marks the step, then always re-raises
      finish(record, handle, started, status: "error", message: self.class.describe(e)) if record && started
      raise
    end

    private

    def next_position
      report.agent_steps.maximum(:position).to_i + 1
    end

    # Only the outermost step subscribes, so nested steps don't double count. Events from other threads
    # (another report running in the same worker process) are ignored.
    def counting_taste_calls(&block)
      return yield if @counting

      @counting = true
      calls = 0
      thread = Thread.current
      counter = ->(*) { calls += 1 if Thread.current.equal?(thread) }
      begin
        ActiveSupport::Notifications.subscribed(counter, "request.taste", &block)
      ensure
        @counting = false
        report.increment!(:taste_calls, calls) if calls.positive?
      end
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
