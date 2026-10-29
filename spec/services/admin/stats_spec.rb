require "rails_helper"

RSpec.describe Admin::Stats do
  subject(:stats) { described_class.new }

  let(:now) { Time.utc(2026, 10, 25, 12) }
  let(:today) { now - 2.hours }
  let(:this_month) { Time.utc(2026, 10, 3, 9) }
  let(:last_month) { Time.utc(2026, 9, 28, 9) }
  let(:show) { create(:show, created_at: last_month, user: create(:user, created_at: last_month)) }

  before { travel_to now }

  def report(kind, status, at:, cost: 0, **attributes)
    create(:report, show: show, kind: kind, status: status, cost_usd: cost, created_at: at, **attributes)
  end

  it "counts new users today and this month" do
    create(:user, created_at: today)
    create(:user, created_at: this_month)
    create(:user, created_at: last_month)
    expect(stats.users).to eq(today: 1, month: 2)
  end

  it "counts reports by kind and status" do
    report("agent", "done", at: today)
    report("agent", "done", at: this_month)
    report("agent", "failed", at: today)
    report("snapshot", "done", at: this_month)
    report("snapshot", "done", at: last_month)

    expect(stats.reports).to eq(today: { %w[agent done] => 1, %w[agent failed] => 1 },
                                month: { %w[agent done] => 2, %w[agent failed] => 1, %w[snapshot done] => 1 })
  end

  it "sums spend by bucket" do
    SpendEntry.create!(bucket: "promo", kind: "llm", cost_usd: 0.4, created_at: today)
    SpendEntry.create!(bucket: "promo", kind: "llm", cost_usd: 0.1, created_at: this_month)
    SpendEntry.create!(bucket: "judge", kind: "llm", cost_usd: 0.25, created_at: this_month)
    SpendEntry.create!(bucket: "paid", kind: "llm", cost_usd: 9, created_at: last_month)

    expect(stats.spend).to eq(today: { "promo" => BigDecimal("0.4") },
                              month: { "promo" => BigDecimal("0.5"), "judge" => BigDecimal("0.25") })
  end

  it "averages the cost of done agent reports only, nil when there are none" do
    report("agent", "done", at: today, cost: 0.5)
    report("agent", "done", at: this_month, cost: 0.3)
    report("agent", "failed", at: today, cost: 0.9)
    report("snapshot", "done", at: today, cost: 0.7)

    expect(stats.average_agent_cost).to eq(today: BigDecimal("0.5"), month: BigDecimal("0.4"))
    expect(described_class.new(now: Time.utc(2026, 8, 1)).average_agent_cost).to eq(today: nil, month: nil)
  end

  it "averages uncached Qloo calls per done report, by kind (R94)" do
    report("agent", "done", at: today, taste_calls: 30)
    report("agent", "done", at: this_month, taste_calls: 20)
    report("agent", "failed", at: today, taste_calls: 90)
    report("snapshot", "done", at: today, taste_calls: 8)
    report("snapshot", "done", at: last_month, taste_calls: 40)

    expect(stats.taste_calls_per_report).to eq(today: { "agent" => 30, "snapshot" => 8 }, month: { "agent" => 25, "snapshot" => 8 })
  end

  it "counts pitches" do
    match = create(:sponsor_match, show: show, report: report("agent", "done", at: last_month))
    Pitch.create!(sponsor_match: match, status: "done", created_at: today)
    Pitch.create!(sponsor_match: match, status: "failed", created_at: this_month)
    Pitch.create!(sponsor_match: match, status: "done", created_at: last_month)
    expect(stats.pitches).to eq(today: 1, month: 2)
  end

  it "splits waitlist entries into notify-me and plan entries" do
    WaitlistEntry.create!(email: "a@example.com", price_key: "notify", created_at: today)
    WaitlistEntry.create!(email: "b@example.com", price_key: "pro_monthly", created_at: today)
    WaitlistEntry.create!(email: "c@example.com", price_key: "sprint", created_at: this_month)
    WaitlistEntry.create!(email: "d@example.com", price_key: "notify", created_at: last_month)

    expect(stats.waitlist).to eq(today: { notify: 1, plans: 1 }, month: { notify: 1, plans: 2 })
  end

  it "reads the promo, judge and daily budgets from Llm::Budget" do
    usage = { promo: { spent: 1, ceiling: 5 } }
    allow(Llm::Budget).to receive(:usage).and_return(usage)
    expect(stats.budgets).to eq(usage)
  end

  it "lists the 20 latest failed reports, newest first, with their shows" do
    oldest = report("agent", "failed", at: last_month, finished_at: last_month, error_message: "oldest")
    20.times { |n| report("agent", "failed", at: this_month, finished_at: this_month + n.minutes, error_message: "n#{n}") }
    report("agent", "done", at: today, finished_at: today)

    failed = stats.failed_reports
    expect(failed.size).to eq(20)
    expect(failed.first.error_message).to eq("n19")
    expect(failed).not_to include(oldest)
    expect(failed.first.association(:show)).to be_loaded
  end

  it "keeps to a handful of aggregate queries, whatever the row count" do
    5.times { |n| report("agent", n.even? ? "done" : "failed", at: today, cost: 0.1) }
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      %i[users reports spend average_agent_cost pitches waitlist].each { |name| stats.public_send(name) }
      stats.failed_reports.to_a
    end
    expect(queries).to be <= 15 # the failed reports preload their shows, then the shows' podcasts
  end
end
