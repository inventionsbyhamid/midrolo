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

      it "lets the research wait for the next minute when Qloo's minute cap is reached, and only there (R109)" do
        waiting = nil
        allow(Research::Run).to receive(:call) { waiting = Taste::CallGuard.waiting? }
        job.perform_now(report.id)

        expect(waiting).to be(true)
        expect(Taste::CallGuard).not_to be_waiting
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

      it "does not mask the original error when the report is deleted mid-run" do
        allow(Research::Run).to receive(:call) { |r| r.destroy!; raise "boom" }
        expect { job.perform_now(report.id) }.not_to raise_error
      end

      # R135: at-least-once delivery. A second delivery reads the report while it is still queued, before this one has
      # started; its start is a conditional update, so only one of them runs the research.
      it "runs the research once when the job is delivered twice at the same time" do
        runs = 0
        allow(Research::Run).to receive(:call) { runs += 1 }
        duplicate = true
        allow(Report).to receive(:find_by).and_wrap_original do |original, *args, **options|
          found = original.call(*args, **options)
          if duplicate
            duplicate = false
            job.perform_now(report.id) # the other delivery, while this one holds a queued copy
          end
          found
        end

        job.perform_now(report.id)

        expect(runs).to eq(1)
        expect(report.reload).to have_attributes(status: "done")
      end

      it "ignores a report that is not queued" do
        report.update!(status: "done")
        expect(Research::Run).not_to receive(:call)
        job.perform_now(report.id)
      end
    end
  end

  it "runs the real engine end to end for a snapshot on Fake providers" do
    Taste::Provider.reset!
    Podcasts::Directory.reset!
    show = create(:show, title: "The Founder's Ledger", feed_url: "fake://fake-1", categories: [ "Business" ])
    report = create(:report, show: show)
    BuildSnapshotJob.perform_now(report.id)

    expect(report.reload.status).to eq("done")
    expect(report.sponsor_matches).to be_present
  end
end
