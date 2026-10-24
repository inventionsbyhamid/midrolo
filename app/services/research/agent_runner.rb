module Research
  # The paid full report: SponsorResearchAgent drives the tools. Before any work it checks the LLM budget;
  # while it runs, the RubyLLM tool callbacks count tool calls and time against the caps (R35: they log no
  # steps; the services and tools do). Spend is recorded once, whatever the outcome.
  #
  # Raises Llm::BudgetExceeded (not allowed to spend), NeedsInput (fewer than 2 seeds saved), LimitReached
  # (a cap was hit before any matches were saved) or IncompleteRun (the model stopped without saving
  # matches). Returns the toolkit.
  class AgentRunner
    ESTIMATE_USD = 0.5

    def self.call(report) = new(report).call

    def initialize(report)
      @report = report
      @toolkit = Toolkit.new(report)
      @tool_calls = 0
    end

    def call
      model = Llm.agent_model
      Llm::Pricing.ensure_known!(model)
      unless Llm::Budget.allow?(report.spend_bucket, estimate_usd: ESTIMATE_USD)
        raise Llm::BudgetExceeded, "LLM budget exhausted for #{report.spend_bucket.inspect}"
      end

      run_agent(model)
      raise IncompleteRun, "the agent stopped without saving sponsor matches" unless matches_saved?

      save_fallback_summary if report.summary.blank?
      toolkit
    end

    private

    attr_reader :report, :toolkit

    def run_agent(model)
      chat = SponsorResearchAgent.chat(toolkit: toolkit, provider: Llm.provider)
      enforce_limits(chat)
      chat.ask(kickoff)
    rescue LimitReached
      raise unless matches_saved? # matches are the report; a late cap only costs the summary
    ensure
      record_spend(chat, model) if chat
    end

    def kickoff
      "Research sponsors for the podcast \"#{toolkit.show.title}\". Start with read_show_feed."
    end

    def enforce_limits(chat)
      started = monotonic
      chat.before_tool_call do |tool_call|
        @tool_calls += 1
        @last_tool = tool_call.name
        check_limits!(started)
      end
      chat.after_tool_result do |_result|
        check_limits!(started)
        raise NeedsInput, "fewer than 2 taste seeds" if @last_tool == "save_taste_seeds" && toolkit.seed_count < 2
      end
    end

    def check_limits!(started)
      max_calls = Llm.agent_max_tool_calls
      raise LimitReached, "more than #{max_calls} tool calls" if @tool_calls > max_calls

      max_seconds = Llm.agent_max_seconds
      raise LimitReached, "over #{max_seconds} seconds" if monotonic - started > max_seconds
    end

    def matches_saved? = report.sponsor_matches.exists?

    def save_fallback_summary
      scored = report.sponsor_matches.filter_map { |m| toolkit.scored[m.brand_entity_id] }
      Tools::SaveSummary.new(toolkit).call(summary: Templates.summary(toolkit, scored))
    end

    # Runs inside an ensure: never let a ledger problem replace the run's own outcome.
    def record_spend(chat, model)
      tokens = chat.tokens
      entry = Llm::Budget.record!(user: toolkit.user, bucket: report.spend_bucket, model: model, report: report,
                                  tokens: { input: tokens.input, output: tokens.output,
                                            cache_read: tokens.cache_read, cache_write: tokens.cache_write })
      report.update!(cost_usd: entry.cost_usd)
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { report_id: report.id, while: "recording agent spend" })
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
