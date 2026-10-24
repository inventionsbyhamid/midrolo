require "rails_helper"

RSpec.describe "Report jobs" do
  [ GenerateReportJob, BuildSnapshotJob ].each do |job|
    describe job do
      let(:report) { create(:report, kind: job == GenerateReportJob ? "agent" : "snapshot") }

      it "runs the engine, marks running then done and stamps the times" do
        statuses = []
        allow(Research::Run).to receive(:call) { |r| statuses << r.reload.status }
        job.perform_now(report.id)

        expect(statuses).to eq([ "running" ])
        expect(report.reload).to have_attributes(status: "done")
        expect(report.started_at).to be_present
        expect(report.finished_at).to be_present
      end

      it "fails with the friendly message and keeps saved sections when the engine raises" do
        allow(Research::Run).to receive(:call) do |r|
          r.save_section!(:summary, "Kept")
          raise "boom"
        end
        expect { job.perform_now(report.id) }.not_to raise_error

        expect(report.reload).to have_attributes(status: "failed", summary: "Kept", error_message: Report::FAILURE_MESSAGE)
        expect(report.finished_at).to be_present
      end

      it "leaves a report the engine finished as needs_input alone" do
        allow(Research::Run).to receive(:call) { |r| r.mark_needs_input! }
        job.perform_now(report.id)
        expect(report.reload.status).to eq("needs_input")
      end

      [ SignalException.new("TERM"), Interrupt.new ].each do |signal|
        it "marks the report failed when interrupted by #{signal.class}" do
          allow(Research::Run).to receive(:call).and_raise(signal)
          expect { job.perform_now(report.id) }.to raise_error(signal.class)
          expect(report.reload).to have_attributes(status: "failed", error_message: Report::FAILURE_MESSAGE)
        end
      end

      it "reports the original error even if marking failed also raises" do
        allow(Research::Run).to receive(:call).and_raise("boom")
        allow_any_instance_of(Report).to receive(:mark_failed!).and_raise("db down")
        expect(Rails.error).to receive(:report).at_least(:twice)
        expect { job.perform_now(report.id) }.not_to raise_error
      end

      it "ignores a report that is not queued" do
        report.update!(status: "done")
        expect(Research::Run).not_to receive(:call)
        job.perform_now(report.id)
      end
    end
  end

  it "fails cleanly while the real engine is not wired yet" do
    report = create(:report)
    BuildSnapshotJob.perform_now(report.id)
    expect(report.reload.status).to eq("failed")
  end
end
