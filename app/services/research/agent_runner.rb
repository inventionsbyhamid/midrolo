module Research
  # The paid full report: SponsorResearchAgent drives the tools. Before any work it checks the LLM budget;
  # while it runs, the RubyLLM tool callbacks count tool calls and time against the caps (R35: they log no
  # steps; the services and tools do). Spend is recorded once, whatever the outcome.
  #
  # The time cap is hard (R39): every request runs in a RubyLLM context whose request_timeout is the time left
  # (split across the one allowed retry), clamped to MIN_REQUEST_SECONDS..MAX_REQUEST_SECONDS whatever
  # max_seconds says, with retry waits capped at MAX_RETRY_INTERVAL. The context is rebound after each tool
  # result, so the final turn after save_summary is bounded too.
  #
  # Seeds: a clean save_taste_seeds call (no rejected ids) that leaves fewer than 2 seeds ends the run as
  # needs_input. A call with rejected ids or invalid arguments may be retried MAX_SEED_RETRIES times.
  #
  # Raises Llm::BudgetExceeded (not allowed to spend), NeedsInput, LimitReached (a cap was hit before any
  # matches were saved; kind :tool_calls or :time) or IncompleteRun (the model stopped without saving
  # matches). Returns the toolkit.
  class AgentRunner
    ESTIMATE_USD = 0.5
    MAX_RETRIES = 1
    MIN_REQUEST_SECONDS = 20
    MAX_REQUEST_SECONDS = 360
    MAX_RETRY_INTERVAL = 5
    MAX_SEED_RETRIES = 2
    TIMEOUTS = [ Faraday::TimeoutError, Timeout::Error ].freeze

    def self.call(report) = new(report).call

    def initialize(report)
      @report = report
      @toolkit = Toolkit.new(report)
      @tool_calls = 0
      @failed_seed_saves = 0
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
      @started = monotonic
      chat = SponsorResearchAgent.chat(toolkit: toolkit, provider: Llm.provider)
      bind_time_budget(chat)
      enforce_limits(chat)
      chat.ask(kickoff)
    rescue LimitReached, *TIMEOUTS => e
      # Matches are the report: a late cap only costs the summary.
      raise(e.is_a?(LimitReached) ? e : LimitReached.new(:time, "request timed out")) unless matches_saved?
    ensure
      record_spend(chat, model) if chat
    end

    def kickoff
      "Research sponsors for the podcast #{Untrusted.wrap(toolkit.show.title)}. Start with read_show_feed."
    end

    def enforce_limits(chat)
      chat.before_tool_call do |tool_call|
        @tool_calls += 1
        @last_tool = tool_call.name
        toolkit.last_seed_save = nil if @last_tool == "save_taste_seeds"
        check_limits!
      end
      chat.after_tool_result do |_result|
        check_limits!
        check_seeds! if @last_tool == "save_taste_seeds"
        bind_time_budget(chat)
      end
    end

    def check_limits!
      max_calls = Llm.agent_max_tool_calls
      raise LimitReached.new(:tool_calls, "more than #{max_calls} tool calls") if @tool_calls > max_calls

      raise LimitReached.new(:time, "over #{Llm.agent_max_seconds} seconds") if seconds_left.negative?
    end

    # No last_seed_save means the call never ran: RubyLLM rejected its arguments.
    def check_seeds!
      outcome = toolkit.last_seed_save
      clean = outcome.present? && outcome[:rejected].zero?
      @failed_seed_saves += 1 unless clean
      return if toolkit.seed_count >= 2

      raise NeedsInput, "fewer than 2 taste seeds" if clean || @failed_seed_saves > MAX_SEED_RETRIES
    end

    # The next request (and its one retry) must fit in the time left.
    def bind_time_budget(chat)
      timeout = (seconds_left / (MAX_RETRIES + 1)).floor.clamp(MIN_REQUEST_SECONDS, MAX_REQUEST_SECONDS)
      chat.with_context(RubyLLM.context do |config|
        config.request_timeout = timeout
        config.max_retries = MAX_RETRIES
        config.retry_max_interval = [ config.retry_max_interval.to_f, MAX_RETRY_INTERVAL ].min
      end)
    end

    def seconds_left = Llm.agent_max_seconds - (monotonic - @started)

    def matches_saved? = report.sponsor_matches.exists?

    def save_fallback_summary
      scored = report.sponsor_matches.filter_map { |m| toolkit.scored[m.brand_entity_id] }
      Tools::SaveSummary.new(toolkit).call(bullets: Templates.summary(toolkit, scored))
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
