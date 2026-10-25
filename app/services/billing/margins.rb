module Billing
  # The go-live guard (R94): "profitable from day 1" checked by code. For every paid price in config/plans.yml, what it
  # nets after worst case Dodo fees (FEE_RATE plus FEE_FIXED_USD a payment) against what its plan costs us when every
  # cap is used: the LLM for its full reports and pitches, and Qloo for its full reports and Snapshots. A yearly price
  # counts 12 months of caps on one payment (usage is counted month by month, R60a); the sprint one period.
  #
  # The unit costs are the app's own estimates, or what done work has measured when that is higher:
  #   LLM per full report: Research::AgentRunner::ESTIMATE_USD, the budget gate's estimate.
  #   LLM per pitch: PITCH_ESTIMATE_USD. The code kept no estimate for a pitch, so this is docs/design.md §11's.
  #   Qloo calls per full report or Snapshot: config/research.yml's max_taste_calls (R93).
  #   Qloo price per call: AppSettings qloo_cost_per_call_usd, set in admin once Qloo quotes; blank until then.
  # Billing.mode refuses :live (the waitlist instead) until the price is set and every paid price keeps MIN_MARGIN.
  module Margins
    FEE_RATE = BigDecimal("0.06")
    FEE_FIXED_USD = BigDecimal("0.40")
    MIN_MARGIN = BigDecimal("0.60")
    PITCH_ESTIMATE_USD = BigDecimal("0.04")
    MONTHS = { monthly: 1, yearly: 12, once: 1 }.freeze
    COST_UNSET = "the Qloo cost per call isn't set".freeze

    # Per unit: LLM USD per full report and per pitch, Qloo calls per full report and per Snapshot, and the Qloo price
    # per call (nil while unset).
    Inputs = Data.define(:agent_llm_usd, :pitch_llm_usd, :agent_calls, :snapshot_calls, :cost_per_call)
    # One paid price at its caps. qloo_usd and margin are nil while the Qloo price is unset.
    Row = Data.define(:price, :label, :net_usd, :llm_usd, :qloo_calls, :qloo_usd, :margin)
    Check = Data.define(:rows, :inputs, :blockers) do
      def ready? = blockers.empty?
    end

    class << self
      def check
        inputs = self.inputs
        rows = Billing.prices.map { |price| row(price, inputs) }
        Check.new(rows: rows, inputs: inputs, blockers: blockers(rows, inputs))
      end

      # The Qloo price per call as set in admin, or nil when blank (or unreadable, or negative).
      def cost_per_call
        value = AppSettings.get(:qloo_cost_per_call_usd).to_s.strip
        cost = BigDecimal(value) unless value.empty?
        cost unless cost&.negative?
      rescue ArgumentError
        nil
      end

      private

      def inputs
        calls = Research.caps.fetch(:max_taste_calls)
        Inputs.new(
          agent_llm_usd: higher(BigDecimal(Research::AgentRunner::ESTIMATE_USD.to_s), Report.agent.done.average(:cost_usd)),
          pitch_llm_usd: higher(PITCH_ESTIMATE_USD, Pitch.done.average(:cost_usd)),
          agent_calls: higher(calls, Report.agent.done.average(:taste_calls)&.ceil),
          snapshot_calls: higher(calls, Report.snapshot.done.average(:taste_calls)&.ceil),
          cost_per_call: cost_per_call
        )
      end

      def higher(estimate, measured) = [ estimate, measured ].compact.max

      def row(price, inputs)
        limits = Entitlements.limits(price.plan.to_sym)
        months = MONTHS.fetch(price.interval.to_sym)
        reports, snapshots, pitches = limits.values_at(:agent_reports, :snapshots_per_month, :pitches).map { |cap| cap * months }
        net = BigDecimal(price.usd.to_s) * (1 - FEE_RATE) - FEE_FIXED_USD
        llm = reports * inputs.agent_llm_usd + pitches * inputs.pitch_llm_usd
        calls = reports * inputs.agent_calls + snapshots * inputs.snapshot_calls
        qloo = inputs.cost_per_call && calls * inputs.cost_per_call
        Row.new(price: price, label: label(price, limits), net_usd: net, llm_usd: llm, qloo_calls: calls, qloo_usd: qloo,
                margin: qloo && (net - llm - qloo) / net)
      end

      # "Creator monthly", "Pro yearly", "Sprint".
      def label(price, limits) = [ limits.fetch(:name), (price.interval.to_s unless price.interval.to_sym == :once) ].compact.join(" ")

      def blockers(rows, inputs)
        return [ COST_UNSET ] unless inputs.cost_per_call

        rows.select { |row| row.margin < MIN_MARGIN }.map do |row|
          "#{row.label} keeps #{(row.margin * 100).floor}% at its caps, under #{(MIN_MARGIN * 100).to_i}%"
        end
      end
    end
  end
end
