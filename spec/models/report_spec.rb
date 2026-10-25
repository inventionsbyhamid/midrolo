require "rails_helper"

RSpec.describe Report do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:show) { create(:show, user: user) }

  # Turbo streams are named by the signed-in-free gid of the streamable, not by an ActionCable channel.
  def stream_for(record) = Turbo::StreamsChannel.send(:stream_name_from, record)

  describe ".start!" do
    it "creates a queued report and enqueues the snapshot job" do
      report = nil
      expect { report = described_class.start!(show: show, kind: "snapshot", user: user) }
        .to have_enqueued_job(BuildSnapshotJob)
      expect(report).to have_attributes(status: "queued", kind: "snapshot", spend_bucket: nil)
    end

    it "enqueues the agent job and records the spend bucket for agent reports" do
      AppSettings.set(:promo_pro_until, 1.week.from_now.to_date.to_s)
      report = nil
      expect { report = described_class.start!(show: show, kind: "agent", user: user) }
        .to have_enqueued_job(GenerateReportJob)
      expect(report.spend_bucket).to eq("promo")
    end

    it "records the paid bucket for a subscriber and the judge bucket for a judge (R62)" do
      create(:subscription, user: user, plan: "creator")
      expect(described_class.start!(show: show, kind: "agent", user: user).spend_bucket).to eq("paid")
      judge = create(:user, judge: true)
      expect(described_class.start!(show: create(:show, user: judge), kind: "agent", user: judge).spend_bucket).to eq("judge")
    end

    it "returns the active report instead of creating another" do
      first = described_class.start!(show: show, kind: "snapshot", user: user)
      expect { @second = described_class.start!(show: show, kind: "agent", user: user) }
        .not_to change(described_class, :count)
      expect(@second).to eq(first)
    end

    it "starts a new report once the previous one is finished" do
      create(:report, show: show, kind: "agent", status: "done")
      expect { described_class.start!(show: show, kind: "snapshot", user: user) }.to change(described_class, :count).by(1)
    end

    it "raises NotAllowed with the plan's reason when the plan does not allow the kind" do
      expect { described_class.start!(show: show, kind: "agent", user: user) }
        .to raise_error(Entitlements::NotAllowed) { |error| expect(error.reason).to eq(:plan) }
      expect(described_class.count).to eq(0)
    end

    it "raises NotAllowed with reason :limit once the period's Snapshot is used" do
      create(:report, show: show, kind: "snapshot", status: "done")
      expect { described_class.start!(show: show, kind: "snapshot", user: user) }
        .to raise_error(Entitlements::NotAllowed) { |error| expect(error.reason).to eq(:limit) }
    end

    it "checks the plan and inserts under the user's advisory lock (R61)" do
      allow(described_class.connection).to receive(:execute).and_call_original
      described_class.start!(show: show, kind: "snapshot", user: user)

      expect(described_class.connection).to have_received(:execute)
        .with("SELECT pg_advisory_xact_lock(#{Entitlements::USAGE_LOCK_NAMESPACE}, #{user.id})")
    end

    it "reserves the user's fresh agent reports still running on other shows against the plan (R61)" do
      user = create(:user)
      create(:subscription, user: user, plan: "pro")
      shows = create_list(:show, 3, user: user)
      11.times { create(:report, show: shows[0], kind: "agent", status: "done") }

      described_class.start!(show: shows[1], kind: "agent", user: user)
      expect { described_class.start!(show: shows[2], kind: "agent", user: user) }
        .to raise_error(Entitlements::NotAllowed) { |error| expect(error.reason).to eq(:limit) }
    end

    it "returns the active report without an entitlement check or raise" do
      active = create(:report, show: show, status: "running", started_at: 1.minute.ago)
      plan = instance_double(Entitlements::Plan, can_run?: false)
      allow(Entitlements).to receive(:for).with(user).and_return(plan)
      expect(described_class.start!(show: show, kind: "agent", user: user)).to eq(active)
    end

    it "fails a stale running report and creates the new one" do
      stale = create(:report, show: show, status: "running", started_at: 20.minutes.ago)
      report = nil
      expect { report = described_class.start!(show: show, kind: "snapshot", user: user) }.to change(described_class, :count).by(1)
      expect(report).not_to eq(stale)
      expect(report).to be_queued
      expect(stale.reload).to have_attributes(status: "failed", error_message: Report::FAILURE_MESSAGE)
    end

    it "fails a stale queued report too" do
      stale = create(:report, show: show, status: "queued")
      stale.update_columns(created_at: 20.minutes.ago)
      described_class.start!(show: show, kind: "snapshot", user: user)
      expect(stale.reload.status).to eq("failed")
    end

    it "returns the report a concurrent start for the show made while it waited for the lock" do
      winner = create(:report, show: show, kind: "agent", status: "queued")
      # Simulate the race: the pre-check saw nothing; by the time the lock was held the other start had committed.
      calls = 0
      allow(show).to receive(:active_report) { (calls += 1) == 1 ? nil : winner }
      expect { expect(described_class.start!(show: show, kind: "agent", user: user)).to eq(winner) }
        .not_to have_enqueued_job
    end

    it "returns the existing active report when a concurrent insert hits the unique index" do
      create(:subscription, user: user, plan: "pro")
      winner = create(:report, show: show, status: "running")
      # Simulate the race: both checks saw nothing, then the insert collided.
      calls = 0
      allow(show).to receive(:active_report) { (calls += 1) <= 2 ? nil : winner }
      expect(described_class.start!(show: show, kind: "snapshot", user: user)).to eq(winner)
    end

    it "enforces one active report per show in the database" do
      create(:report, show: show, status: "queued")
      expect { create(:report, show: show, status: "running") }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "status broadcasts" do
    it "broadcasts a page refresh on every status transition" do
      report = create(:report, show: show)
      %w[running done failed needs_input].each do |status|
        expect { report.update!(status: status) }
          .to have_broadcasted_to(stream_for(report)).with { |html| expect(html).to include('action="refresh"') }
        report.update_columns(status: "queued")
      end
    end

    it "does not refresh when the status is unchanged" do
      report = create(:report, show: show)
      expect { report.update!(summary: "x") }.not_to have_broadcasted_to(stream_for(report))
    end
  end

  describe "#save_section!" do
    let(:report) { create(:report, show: show, status: "running") }

    it "stores the data and broadcasts a replace to the section target" do
      expect { report.save_section!(:summary, "A show about money.") }
        .to have_broadcasted_to(stream_for(report))
      expect(report.reload.summary).to eq("A show about money.")
    end

    it "targets report_<name> with the section partial" do
      expect { report.save_section!(:audience, { "brands" => [ { "name" => "Acme" } ] }) }
        .to have_broadcasted_to(stream_for(report)).with { |html|
          expect(html).to include('action="replace"', 'target="report_audience"', "Acme")
        }
    end

    it "maps leans to demographics and map to heatmap" do
      report.save_section!(:leans, { "age" => [] })
      report.save_section!(:map, { "location" => "US", "points" => [] })
      expect(report.reload).to have_attributes(demographics: { "age" => [] }, heatmap: { "location" => "US", "points" => [] })
    end

    it "rejects unknown sections" do
      expect { report.save_section!(:bogus, 1) }.to raise_error(ArgumentError)
    end
  end

  describe AgentStep do
    let(:report) { create(:report, show: show, status: "running") }

    it "appends on create and replaces on update" do
      step = nil
      expect { step = create(:agent_step, report: report) }
        .to have_broadcasted_to(stream_for(report)).with { |html|
          expect(html).to include('action="append"', %(target="agent_steps_report_#{report.id}"))
        }
      expect { step.update!(status: "ok", duration_ms: 1200) }
        .to have_broadcasted_to(stream_for(report)).with { |html|
          expect(html).to include('action="replace"', %(target="#{ActionView::RecordIdentifier.dom_id(step)}"), "1.2s")
        }
    end
  end
end
