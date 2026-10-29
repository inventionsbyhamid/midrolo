require "rails_helper"

RSpec.describe Entitlements do
  let(:user) { create(:user) }
  let(:show) { create(:show, user: user) }

  def report(kind, status: "done", bucket: nil, at: Time.current, on: show)
    create(:report, show: on, kind: kind, status: status, spend_bucket: bucket, created_at: at)
  end

  # On a report from an earlier period, so only the pitch counts.
  def pitch(status: "done", at: Time.current)
    match = create(:sponsor_match, report: report("agent", bucket: "paid", at: 3.months.ago))
    Pitch.create!(sponsor_match: match, status: status, created_at: at)
  end

  def subscribe(plan, **attributes) = create(:subscription, user: user, plan: plan, **attributes)

  def reason(plan, kind)
    plan.authorize!(kind)
    nil
  rescue Entitlements::NotAllowed => e
    e.reason
  end

  describe ".for" do
    it "gives a signed-out visitor (nil) the free plan, without touching request state" do
      plan = described_class.for(nil)
      expect(plan.key).to eq(:free)
      expect(plan.snapshots_left).to eq(1)
      expect(plan.spend_bucket).to be_nil
    end

    it "resolves subscription first, then judge, then promo, then free" do
      AppSettings.set(:promo_pro_until, 1.week.from_now.to_date.to_s)
      expect(described_class.for(user).key).to eq(:promo)
      user.update!(judge: true)
      expect(described_class.for(user).key).to eq(:judge)
      subscribe("creator")
      expect(described_class.for(user).key).to eq(:creator)
    end

    it "lets the best entitling plan win: pro and sprint over creator" do
      subscribe("creator")
      subscribe("sprint", current_period_start: 1.day.ago, current_period_end: 29.days.from_now)
      expect(described_class.for(user).key).to eq(:sprint)
    end

    it "ignores a subscription that no longer entitles" do
      subscribe("pro", status: "canceled", current_period_end: 1.day.ago)
      expect(described_class.for(user).key).to eq(:free)
    end
  end

  describe "free" do
    subject(:plan) { described_class.for(user) }

    it "has Snapshot-only limits and the kit badge" do
      expect(plan).to have_attributes(key: :free, max_shows: 1, visible_matches_limit: 5, kit_badge?: true,
                                      csv_export?: false, pipeline?: false, scan_limit: 8, can_pitch?: false)
      expect(plan.can_run?(:agent)).to be false
      expect(reason(plan, :agent)).to eq(:plan)
      expect(reason(plan, :pitch)).to eq(:plan)
    end

    it "runs one Snapshot a month" do
      travel_to Time.zone.local(2026, 10, 20, 12) do
        expect(plan.can_run?(:snapshot)).to be true
        report("snapshot")
        expect(plan.can_run?(:snapshot)).to be false
        expect(reason(plan, :snapshot)).to eq(:limit)
        expect(plan.snapshots_left).to eq(0)
      end
      travel_to Time.zone.local(2026, 11, 1, 0, 1) do
        expect(plan.snapshots_left).to eq(1)
        expect(plan.can_run?(:snapshot)).to be true
      end
    end
  end

  describe "creator" do
    before { subscribe("creator", current_period_start: 5.days.ago, current_period_end: 25.days.from_now) }

    let(:plan) { described_class.for(user) }

    it "has every match, the pipeline, no badge and no CSV" do
      expect(plan).to have_attributes(key: :creator, max_shows: 1, visible_matches_limit: 50, kit_badge?: false,
                                      csv_export?: false, pipeline?: true, scan_limit: 8, can_pitch?: true,
                                      pitches_left: 40, snapshots_left: 4)
    end

    it "runs 4 agent reports, then refuses with reason :limit" do
      3.times { report("agent", bucket: "paid") }
      expect(plan.agent_reports_left).to eq(1)
      expect(plan.can_run?(:agent)).to be true
      report("agent", bucket: "paid")
      expect(plan.agent_reports_left).to eq(0)
      expect(plan.can_run?(:agent)).to be false
      expect { plan.authorize!(:agent) }.to raise_error(Entitlements::NotAllowed) { |e| expect(e.reason).to eq(:limit) }
    end

    it "counts usage from the subscription's period start" do
      4.times { report("agent", bucket: "paid", at: 6.days.ago) }
      expect(plan.agent_reports_left).to eq(4)
      expect(plan.agent_reports_left(7.days.ago)).to eq(0)
    end

    it "counts only done reports and done pitches: failed and needs_input never use quota" do
      report("agent", status: "failed", bucket: "paid")
      report("agent", status: "needs_input", bucket: "paid")
      pitch(status: "failed")
      expect(plan.agent_reports_left).to eq(4)
      expect(plan.pitches_left).to eq(40)
      pitch
      expect(plan.pitches_left).to eq(39)
    end

    it "reserves fresh in-flight agent reports in the gate, but not stale ones (R61)" do
      3.times { report("agent", bucket: "paid") }
      other_show = create(:show, user: user)
      report("agent", status: "queued", bucket: "paid", on: other_show)
      expect(plan.agent_reports_left).to eq(1) # done only
      expect(reason(plan, :agent)).to eq(:limit)

      Report.where(status: "queued").update_all(created_at: (Report::STALE_AFTER + 1.minute).ago)
      expect(plan.can_run?(:agent)).to be true
    end

    it "reserves pitches still being written (R53)" do
      39.times { pitch }
      expect(plan.can_run?(:pitch)).to be true
      pitch(status: "queued")
      expect(reason(plan, :pitch)).to eq(:limit)
    end

    it "refuses when the daily LLM cap is reached, with reason :budget" do
      allow(Llm::Budget).to receive(:allow?).with(:paid).and_return(false)
      expect(reason(plan, :agent)).to eq(:budget)
      expect(reason(plan, :pitch)).to eq(:budget)
      expect(plan.can_run?(:snapshot)).to be true
    end

    it "talks about the billing period" do
      expect(plan.period_name).to eq("billing period")
    end
  end

  describe "a subscription's usage window (R60a)" do
    it "counts a yearly plan month by month from its start, with month wording" do
      travel_to(Time.zone.local(2026, 10, 25, 12)) do
        subscribe("creator", price_key: "creator_yearly", current_period_start: Time.zone.local(2026, 5, 10, 9),
                             current_period_end: Time.zone.local(2027, 5, 10, 9))
        report("agent", bucket: "paid", at: Time.zone.local(2026, 10, 10, 8)) # the window before
        2.times { report("agent", bucket: "paid", at: Time.zone.local(2026, 10, 10, 10)) }
        plan = described_class.for(user)

        expect(plan.period_start).to eq(Time.zone.local(2026, 10, 10, 9))
        expect(plan.agent_reports_left).to eq(2)
        expect(plan.period_name).to eq("month")
      end
    end

    it "anchors a month-end start on the last day of shorter months" do
      start = Time.zone.local(2027, 1, 31, 9)
      subscribe("creator", current_period_start: start, current_period_end: start.advance(years: 1))
      { Time.zone.local(2027, 2, 28, 8) => start,
        Time.zone.local(2027, 2, 28, 10) => Time.zone.local(2027, 2, 28, 9),
        Time.zone.local(2027, 3, 30, 12) => Time.zone.local(2027, 2, 28, 9),
        Time.zone.local(2027, 3, 31, 10) => Time.zone.local(2027, 3, 31, 9) }.each do |now, window|
        travel_to(now) { expect(described_class.for(user).period_start).to eq(window) }
      end
    end

    it "anchors on Feb 29 in a leap year" do
      start = Time.zone.local(2028, 1, 31, 9)
      subscribe("pro", current_period_start: start, current_period_end: start.advance(years: 1))
      travel_to(Time.zone.local(2028, 3, 1, 12)) do
        expect(described_class.for(user).period_start).to eq(Time.zone.local(2028, 2, 29, 9))
      end
    end

    it "never starts a window past the period's end while a late renewal is pending" do
      subscribe("creator", current_period_start: Time.zone.local(2025, 10, 20), current_period_end: Time.zone.local(2026, 10, 18))
      travel_to(Time.zone.local(2026, 10, 20, 12)) do
        expect(described_class.for(user).period_start).to eq(Time.zone.local(2026, 10, 18))
      end
    end

    it "keeps a monthly plan and the 30-day sprint as one window, even across a short month or in the grace" do
      start = Time.zone.local(2027, 2, 1, 9)
      sprint = subscribe("sprint", current_period_start: start, current_period_end: start + 30.days)
      travel_to(Time.zone.local(2027, 3, 2, 12)) do
        plan = described_class.for(user)
        expect(plan).to have_attributes(key: :sprint, period_start: start, period_name: "billing period")
      end

      sprint.destroy!
      subscribe("creator", current_period_start: Time.zone.local(2026, 9, 25, 9), current_period_end: Time.zone.local(2026, 10, 25, 9))
      travel_to(Time.zone.local(2026, 10, 26, 12)) do
        expect(described_class.for(user).period_start).to eq(Time.zone.local(2026, 9, 25, 9))
      end
    end

    it "falls back to the calendar month, with month wording, without a period start" do
      subscribe("creator", current_period_start: nil)
      travel_to(Time.zone.local(2026, 10, 25, 12)) do
        expect(described_class.for(user)).to have_attributes(period_start: Time.zone.local(2026, 10, 1), period_name: "month")
      end
    end
  end

  describe "pro and sprint" do
    it "gives pro 3 shows, a deeper scan and CSV export" do
      subscribe("pro")
      expect(described_class.for(user)).to have_attributes(
        key: :pro, max_shows: 3, scan_limit: 12, csv_export?: true, pipeline?: true, kit_badge?: false,
        visible_matches_limit: 50, agent_reports_left: 12, pitches_left: 150, snapshots_left: 12
      )
    end

    it "gives a sprint Pro for its 30 days" do
      subscribe("sprint", current_period_start: 1.day.ago, current_period_end: 29.days.from_now)
      expect(described_class.for(user)).to have_attributes(
        key: :sprint, max_shows: 3, scan_limit: 12, csv_export?: true, agent_reports_left: 12, pitches_left: 150
      )
      travel 30.days
      expect(described_class.for(user).key).to eq(:free)
    end
  end

  describe "promo" do
    before { AppSettings.set(:promo_pro_until, "2026-11-06") }

    # R151: the trial is 3 shows, each with a Snapshot and a full report.
    it "gives Pro features with 3 shows, 3 Snapshots and 3 agent reports in total, then reason :limit" do
      travel_to Time.zone.local(2026, 10, 25, 12) do
        plan = described_class.for(user)
        expect(plan).to have_attributes(key: :promo, max_shows: 3, pipeline?: true, csv_export?: true, kit_badge?: false,
                                        scan_limit: 12, visible_matches_limit: 50, pitches_left: 60, snapshots_left: 3,
                                        spend_bucket: :promo)
        expect(plan.can_run?(:agent)).to be true
        3.times { report("agent", bucket: "promo", at: 1.month.ago) }
        expect(plan.agent_reports_left).to eq(0)
        expect(reason(plan, :agent)).to eq(:limit)
      end
    end

    it "counts only promo-bucket agent reports toward the promo" do
      travel_to Time.zone.local(2026, 10, 25, 12) do
        report("agent", bucket: "judge")
        expect(described_class.for(user).agent_reports_left).to eq(3)
      end
    end

    it "runs through Nov 6 inclusive; after Nov 6, 2026 the plan is free" do
      travel_to Time.zone.local(2026, 11, 6, 23, 59) { expect(described_class.for(user).key).to eq(:promo) }
      travel_to Time.zone.local(2026, 11, 7, 0, 1) { expect(described_class.for(user).key).to eq(:free) }
    end

    it "refuses with reason :budget once the promo pool is spent" do
      travel_to Time.zone.local(2026, 10, 25, 12) do
        SpendEntry.create!(bucket: "promo", kind: "llm", cost_usd: 5)
        expect(reason(described_class.for(user), :agent)).to eq(:budget)
      end
    end
  end

  describe "the capped Qloo lane (R108)" do
    let(:promo_until) { (Date.current + 7).iso8601 }

    def spend_the_share
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      AppSettings.set(:qloo_daily_call_limit, 10) # a share of 0.4: 4 calls
      Taste::CallGuard.lane(:capped) { 4.times { Taste::CallGuard.new.acquire! } }
    end

    it "caps free and promo users, never judges or paying users" do
      expect(described_class.for(user)).to be_capped_taste
      AppSettings.set(:promo_pro_until, promo_until)
      expect(described_class.for(user)).to have_attributes(key: :promo, capped_taste?: true)
      expect(described_class.for(create(:user, judge: true))).not_to be_capped_taste
      expect(described_class.for(create(:user, :subscribed))).not_to be_capped_taste
    end

    it "refuses a capped user's Snapshot or report with reason :busy once the share of today's calls is spent" do
      AppSettings.set(:promo_pro_until, promo_until)
      expect(reason(described_class.for(user), :agent)).to be_nil
      spend_the_share

      expect(reason(described_class.for(user), :snapshot)).to eq(:busy)
      expect(reason(described_class.for(user), :agent)).to eq(:busy)
      expect(reason(described_class.for(user), :pitch)).to be_nil # pitches make no Qloo calls
      expect(reason(described_class.for(create(:user, judge: true)), :agent)).to be_nil
      expect(reason(described_class.for(create(:user, :subscribed)), :agent)).to be_nil
    end

    it "keeps the plan's own refusals first" do
      spend_the_share
      report("snapshot")
      expect(reason(described_class.for(user), :snapshot)).to eq(:limit)
    end
  end

  describe "judge" do
    before { user.update!(judge: true) }

    let(:plan) { described_class.for(user) }

    it "gives Pro features with 3 shows, unlimited pitches and 12 Snapshots a month" do
      expect(plan).to have_attributes(key: :judge, max_shows: 3, pipeline?: true, csv_export?: true, kit_badge?: false,
                                      scan_limit: 12, snapshots_left: 12, spend_bucket: :judge, can_pitch?: true)
      expect(plan.pitches_left).to eq(Float::INFINITY)
      expect(plan.can_run?(:pitch)).to be true
    end

    it "runs 3 agent reports in total" do
      2.times { report("agent", bucket: "judge", at: 2.months.ago) }
      report("agent", bucket: "promo")
      expect(plan.agent_reports_left).to eq(1)
      report("agent", bucket: "judge")
      expect(reason(plan, :agent)).to eq(:limit)
    end

    it "refuses with reason :budget when Llm::Budget.allow?(:judge) is false" do
      allow(Llm::Budget).to receive(:allow?).with(:judge).and_return(false)
      expect(reason(plan, :agent)).to eq(:budget)
      expect(reason(plan, :pitch)).to eq(:budget)
    end

    it "draws on the judge reserve even with a Pro subscription (R62a)" do
      subscribe("pro")
      expect(described_class.for(user)).to have_attributes(key: :pro, spend_bucket: :judge)
    end

    it "talks about the month" do
      expect(plan.period_name).to eq("month")
    end
  end

  describe "when runs are paused" do
    before { AppSettings.set(:runs_paused, true) }

    it "refuses every kind on every plan with reason :paused, before any limit" do
      AppSettings.set(:promo_pro_until, 1.week.from_now.to_date.to_s)
      judge = create(:user, judge: true)
      creator = create(:user)
      create(:subscription, user: creator, plan: "creator")
      pro = create(:user)
      create(:subscription, user: pro, plan: "pro")
      sprint = create(:user)
      create(:subscription, user: sprint, plan: "sprint", current_period_end: 29.days.from_now)
      free_plan = described_class::Plan.new(:free, user: create(:user))

      plans = [ described_class.for(user), described_class.for(judge), described_class.for(creator),
                described_class.for(pro), described_class.for(sprint), free_plan ]
      expect(plans.map(&:key)).to eq(%i[promo judge creator pro sprint free])
      plans.each do |plan|
        %i[snapshot agent pitch].each { |kind| expect(reason(plan, kind)).to eq(:paused) }
      end
    end
  end

  describe ".promo_active?" do
    it "is inclusive through promo_pro_until and false when unset or unparseable" do
      expect(described_class.promo_active?).to be false
      AppSettings.set(:promo_pro_until, Date.current.to_s)
      expect(described_class.promo_active?).to be true
      AppSettings.set(:promo_pro_until, 1.day.ago.to_date.to_s)
      expect(described_class.promo_active?).to be false
      AppSettings.set(:promo_pro_until, "garbage")
      expect(described_class.promo_active?).to be false
    end
  end

  describe "a refusal's details" do
    it "captures the counts the upgrade prompt shows, as they were when the plan refused (R63)" do
      subscribe("creator")
      3.times { report("agent", bucket: "paid") }
      report("agent", status: "running", bucket: "paid", on: create(:show, user: user))
      expect { described_class.for(user).authorize!(:agent) }.to raise_error(Entitlements::NotAllowed) { |error|
        expect(error.details).to eq(reason: :limit, kind: :agent, bucket: :paid, used: 3, in_flight: 1, limit: 4,
                                    period: "billing period")
      }
    end

    it "leaves the counts out for other reasons, and the period out where the plan counts in total" do
      expect { described_class.for(user).authorize!(:agent) }.to raise_error(Entitlements::NotAllowed) { |error|
        expect(error.details).to eq(reason: :plan, kind: :agent, bucket: nil)
      }

      travel_to(Time.zone.local(2026, 10, 25, 12)) do
        AppSettings.set(:promo_pro_until, "2026-11-06")
        3.times { report("agent", bucket: "promo") }
        expect { described_class.for(user).authorize!(:agent) }.to raise_error(Entitlements::NotAllowed) { |error|
          expect(error.details).to include(reason: :limit, used: 3, limit: 3, period: nil, bucket: :promo)
        }
      end
    end
  end

  describe "stub_plan" do
    it "changes plans.yml values, so the predicates and the gate agree" do
      stub_plan(pitches: 0)
      plan = described_class.for(user)
      expect(plan.can_pitch?).to be false
      expect(plan.can_run?(:pitch)).to be false
      expect(reason(plan, :pitch)).to eq(:plan)

      stub_plan(pitches: 1)
      pitch
      plan = described_class.for(user)
      expect(plan.pitches_left).to eq(0)
      expect(plan.can_run?(:pitch)).to be false
      expect(reason(plan, :pitch)).to eq(:limit)
    end

    it "refuses a value plans.yml doesn't have" do
      expect { stub_plan(can_pitch?: false) }.to raise_error(ArgumentError, /can_pitch\?/)
    end
  end

  describe ".lock_usage!" do
    it "refuses to run outside a transaction, where the lock would end at once" do
      allow(ActiveRecord::Base.connection).to receive(:transaction_open?).and_return(false)
      expect { described_class.lock_usage!(user) }.to raise_error(/inside a transaction/)
    end

    it "takes a transaction-scoped advisory lock on the user in its own namespace" do
      allow(ActiveRecord::Base.connection).to receive(:execute).and_call_original
      ActiveRecord::Base.transaction { described_class.lock_usage!(user) }

      expect(ActiveRecord::Base.connection).to have_received(:execute)
        .with("SELECT pg_advisory_xact_lock(#{Entitlements::USAGE_LOCK_NAMESPACE}, #{user.id})")
      expect(Entitlements::USAGE_LOCK_NAMESPACE).not_to eq(ShowVerification::ADDRESS_LOCK_NAMESPACE)
    end
  end

  it "defines NotAllowed with a reason" do
    error = described_class::NotAllowed.new(:limit)
    expect(error).to be_a(StandardError)
    expect(error.reason).to eq(:limit)
  end
end
