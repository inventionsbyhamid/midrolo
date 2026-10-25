# Formatting for the admin dashboard (admin/dashboard/index) over Admin::Stats.
module AdminHelper
  ADMIN_PERIODS = { today: "Today", month: "This month" }.freeze

  def admin_usd(amount) = number_to_currency(amount || 0)

  # A spent-of-ceiling meter for one of Llm::Budget.usage's rows: "$1.25 of $5.00".
  def admin_budget_meter(label, usage)
    spent, ceiling = usage.values_at(:spent, :ceiling)
    share = ceiling.positive? ? spent / ceiling : (spent.positive? ? 1 : 0)
    ui_meter(share, label: label, value_text: "#{admin_usd(spent)} of #{admin_usd(ceiling)}")
  end

  # A used-of-cap meter for a count of calls: "Qloo calls today", "12 / 100".
  def admin_call_meter(label, used, cap)
    share = cap.positive? ? used.fdiv(cap) : (used.positive? ? 1 : 0)
    ui_meter(share, label: label, value_text: "#{used} / #{cap}")
  end

  # The Totals table: { group heading (nil for the first group) => [[row label, { today:, month: }]] }.
  def admin_total_groups(stats)
    { nil => admin_headline_rows(stats), "Reports" => admin_report_rows(stats), "Spend" => admin_spend_rows(stats) }
  end

  private

  def admin_headline_rows(stats)
    waitlist = stats.waitlist
    [ [ "New users", stats.users ],
      [ "Pitches", stats.pitches ],
      [ "Waitlist: notify me", waitlist.transform_values { |counts| counts[:notify] } ],
      [ "Waitlist: plans", waitlist.transform_values { |counts| counts[:plans] } ],
      [ "Average cost per done full report",
        stats.average_agent_cost.transform_values { |average| average ? admin_usd(average) : "None" } ] ]
  end

  # One row per kind and status seen this month.
  def admin_report_rows(stats)
    seen = Report::KINDS.product(Report::STATUSES).select { |pair| stats.reports[:month].key?(pair) }
    seen.map do |kind, status|
      [ "#{kind.humanize} · #{status.humanize(capitalize: false)}",
        stats.reports.transform_values { |counts| counts.fetch([ kind, status ], 0) } ]
    end
  end

  # Every bucket, then the total.
  def admin_spend_rows(stats)
    rows = SpendEntry::BUCKETS.map { |bucket| [ bucket.humanize, stats.spend.transform_values { |sums| admin_usd(sums[bucket]) } ] }
    rows << [ "Total", stats.spend.transform_values { |sums| admin_usd(sums.values.sum) } ]
  end
end
