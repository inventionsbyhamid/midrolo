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

    it "gives Pro features with 1 agent report in total, then reason :limit" do
      travel_to Time.zone.local(2026, 10, 25, 12) do
        plan = described_class.for(user)
        expect(plan).to have_attributes(key: :promo, max_shows: 1, pipeline?: true, csv_export?: true, kit_badge?: false,
                                        scan_limit: 12, visible_matches_limit: 50, pitches_left: 20, snapshots_left: 1,
                                        spend_bucket: :promo)
        expect(plan.can_run?(:agent)).to be true
        report("agent", bucket: "promo", at: 1.month.ago)
        expect(plan.agent_reports_left).to eq(0)
        expect(reason(plan, :agent)).to eq(:limit)
      end
    end

    it "counts only promo-bucket agent reports toward the promo" do
      travel_to Time.zone.local(2026, 10, 25, 12) do
        report("agent", bucket: "judge")
        expect(described_class.for(user).agent_reports_left).to eq(1)
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

  describe ".lock_usage!" do
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
