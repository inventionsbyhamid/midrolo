module Research
  # Runs a report's research and settles the outcomes it understands; the job marks a still-running report
  # done afterwards, and fails it on anything else.
  #   snapshot             → ScriptedRunner without reasons (never touches Llm)
  #   agent, fake LLM mode → ScriptedRunner with templated reasons
  #   agent                → AgentRunner
  # Fewer than 2 seeds ends needs_input (Review Focus #1). A Qloo auth error fails the report and counts
  # toward pausing runs (Review Focus #4). A required taste call refused by the call guard, or rate limited by Qloo,
  # fails it as busy (R92). A failed report is never charged. A finished run picks up the podcaster's pipeline work
  # from the show's earlier reports (R46). Returns the run's toolkit, or nil when the run didn't finish.
  class Run
    PAUSED_MESSAGE = "Full reports are paused right now. Nothing was charged. Try again later.".freeze
    BUSY_MESSAGE = "Taste data is busy right now. Try again later.".freeze
    LIMIT_MESSAGES = {
      tool_calls: "The research needed more steps than one report allows, so we stopped it. Nothing was charged. Try again.",
      time: "The research took too long, so we stopped it. Nothing was charged. Try again."
    }.freeze

    def self.call(report) = new(report).call

    def initialize(report)
      @report = report
    end

    def call
      toolkit = runner
      AppSettings.reset_taste_auth_failures!
      carry_pipeline_forward
      toolkit
    rescue NeedsInput
      AppSettings.reset_taste_auth_failures! # Qloo answered; there just wasn't enough to go on
      @report.mark_needs_input!
      nil
    rescue Taste::AuthError => e
      AppSettings.record_taste_auth_failure!
      fail_with(e)
    rescue Taste::RateLimited => e
      # Our own cap is expected on a busy day; only Qloo's 429 is worth an error report.
      fail_with(e.is_a?(Taste::CallCapReached) ? nil : e, BUSY_MESSAGE)
    rescue Llm::BudgetExceeded
      fail_with(nil, PAUSED_MESSAGE)
    rescue LimitReached => e
      fail_with(e, LIMIT_MESSAGES.fetch(e.kind, LIMIT_MESSAGES[:time]))
    rescue IncompleteRun => e
      fail_with(e)
    end

    private

    def runner
      return ScriptedRunner.call(@report, with_reasons: false) if @report.snapshot?
      return ScriptedRunner.call(@report, with_reasons: true) if Llm.mode == :fake

      AgentRunner.call(@report)
    end

    # Statuses, notes and follow-up dates move onto the new matches from each brand's latest copy on the show's
    # earlier reports (R46a). A failure here must not fail a good report.
    def carry_pipeline_forward
      SponsorMatch.carry_forward!(@report)
    rescue StandardError => e
      Rails.logger.error("[Research::Run] carrying the pipeline forward failed for report #{@report.id}: #{e.class}: #{e.message}")
      Rails.error.report(e, handled: true, context: { report_id: @report.id, while: "carrying the pipeline forward" })
    end

    def fail_with(error, message = Report::FAILURE_MESSAGE)
      Rails.error.report(error, handled: true, context: { report_id: @report.id }) if error
      @report.mark_failed!(message)
      nil
    end
  end
end
