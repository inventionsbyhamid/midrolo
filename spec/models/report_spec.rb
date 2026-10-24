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
      allow(Llm::Budget).to receive(:bucket_for).with(user).and_return(:promo)
      report = nil
      expect { report = described_class.start!(show: show, kind: "agent", user: user) }
        .to have_enqueued_job(GenerateReportJob)
      expect(report.spend_bucket).to eq("promo")
    end

    it "returns the active report instead of creating another" do
      first = described_class.start!(show: show, kind: "snapshot", user: user)
      expect { @second = described_class.start!(show: show, kind: "agent", user: user) }
        .not_to change(described_class, :count)
      expect(@second).to eq(first)
    end

    it "starts a new report once the previous one is finished" do
      create(:report, show: show, status: "done")
      expect { described_class.start!(show: show, kind: "snapshot", user: user) }.to change(described_class, :count).by(1)
    end

    it "raises NotAllowed when the plan does not allow the kind" do
      plan = instance_double(Entitlements::Plan, can_run?: false)
      allow(Entitlements).to receive(:for).with(user).and_return(plan)
      expect { described_class.start!(show: show, kind: "agent", user: user) }.to raise_error(Entitlements::NotAllowed)
      expect(described_class.count).to eq(0)
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

    it "returns the existing active report when a concurrent insert hits the unique index" do
      winner = create(:report, show: show, status: "running")
      # Simulate the race: the pre-check saw nothing, then the insert collided.
      calls = 0
      allow(show).to receive(:active_report) { (calls += 1) == 1 ? nil : winner }
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
          expect(html).to include('action="append"', 'target="agent_steps"')
        }
      expect { step.update!(status: "ok", duration_ms: 1200) }
        .to have_broadcasted_to(stream_for(report)).with { |html|
          expect(html).to include('action="replace"', %(target="#{ActionView::RecordIdentifier.dom_id(step)}"), "1.2s")
        }
    end
  end
end
