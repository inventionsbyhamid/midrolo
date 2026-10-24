require "rails_helper"

RSpec.describe Research::Run do
  let(:show) do
    create(:show, title: "The Founder's Ledger", feed_url: "fake://fake-1", categories: [ "Business", "Finance" ],
                  hints: { comparable_shows: [ "Index Fund Mornings" ], topics: [] })
  end

  before do
    Taste::Provider.reset!
    Podcasts::Directory.reset!
  end

  def run(report)
    report.mark_running!
    described_class.call(report)
    report.reload
  end

  it "runs a snapshot with the scripted runner, without reasons, never touching Llm" do
    report = create(:report, show: show, kind: "snapshot")
    expect(Llm).not_to receive(:mode)
    expect(Llm::Budget).not_to receive(:record!)
    expect(Llm::Budget).not_to receive(:allow?)
    expect(Research::ScriptedRunner).to receive(:call).with(report, with_reasons: false).and_call_original

    run(report)
    expect(report.status).to eq("running") # the job marks it done
    expect(report.sponsor_matches).to be_present
    expect(report.sponsor_matches.map(&:reason)).to all(be_nil)
    expect(SpendEntry.count).to eq(0)
  end

  it "runs an agent report with the scripted runner and reasons in fake LLM mode" do
    report = create(:report, show: show, kind: "agent")
    allow(Llm).to receive(:mode).and_return(:fake)
    expect(Research::AgentRunner).not_to receive(:call)

    run(report)
    expect(report.sponsor_matches.map(&:reason)).to all(be_present)
    expect(report.summary).to be_present
  end

  it "runs the agent runner in live mode" do
    report = create(:report, show: show, kind: "agent")
    allow(Llm).to receive(:mode).and_return(:live)
    expect(Research::AgentRunner).to receive(:call).with(report).and_return(nil)
    run(report)
  end

  it "returns the toolkit so callers can check provenance" do
    report = create(:report, show: show, kind: "snapshot")
    report.mark_running!
    toolkit = described_class.call(report)
    expect(toolkit).to be_a(Research::Toolkit)
    expect(toolkit.seen_entity_ids).to include(*report.sponsor_matches.pluck(:brand_entity_id))
  end

  describe "carrying the pipeline forward (R46)" do
    def finished_snapshot
      run(create(:report, show: show, kind: "snapshot")).tap(&:mark_done!)
    end

    it "brings each brand's latest status, notes and follow-up onto the new report" do
      first = finished_snapshot
      pitched, saved = first.sponsor_matches.first(2)
      pitched.update!(status: "pitched", notes: "Emailed Sam", follow_up_on: Date.new(2026, 11, 2))
      saved.update!(status: "saved")

      second = finished_snapshot
      expect(second.sponsor_matches.find_by!(brand_entity_id: pitched.brand_entity_id))
        .to have_attributes(status: "pitched", notes: "Emailed Sam", follow_up_on: Date.new(2026, 11, 2))
      second.sponsor_matches.find_by!(brand_entity_id: pitched.brand_entity_id).update!(status: "won", notes: "Signed for Q1")

      third = finished_snapshot
      expect(third.sponsor_matches.find_by!(brand_entity_id: pitched.brand_entity_id))
        .to have_attributes(status: "won", notes: "Signed for Q1", follow_up_on: Date.new(2026, 11, 2))
      expect(third.sponsor_matches.find_by!(brand_entity_id: saved.brand_entity_id).status).to eq("saved")
      expect(third.sponsor_matches.where(status: "suggested").count).to eq(third.sponsor_matches.count - 2)
    end

    it "carries nothing from another show's reports" do
      first = finished_snapshot
      brand = first.sponsor_matches.first.brand_entity_id
      other = create(:report, show: create(:show, user: show.user), kind: "agent", status: "done")
      create(:sponsor_match, report: other, brand_entity_id: brand, status: "won")

      second = finished_snapshot
      expect(second.sponsor_matches.find_by!(brand_entity_id: brand).status).to eq("suggested")
    end

    it "runs fine with no earlier reports" do
      report = create(:report, show: show, kind: "snapshot")
      report.mark_running!
      expect(described_class.call(report)).to be_a(Research::Toolkit)
      expect(report.reload.status).to eq("running")
    end

    it "keeps an otherwise good report when carrying forward fails, and reports the error" do
      finished_snapshot
      error = ActiveRecord::StatementInvalid.new("boom")
      allow(SponsorMatch).to receive(:carry_forward!).and_raise(error)
      allow(Rails.error).to receive(:report)

      report = create(:report, show: show, kind: "snapshot")
      report.mark_running!
      expect(described_class.call(report)).to be_a(Research::Toolkit)

      expect(report.reload.status).to eq("running") # the job marks it done
      expect(report.sponsor_matches).to be_present
      expect(Rails.error).to have_received(:report).with(error, hash_including(handled: true))
    end
  end

  context "when the show has zero seeds (Review Focus #1)" do
    let(:show) do
      create(:show, title: "Totally Unknown Indie Show", feed_url: "fake://fake-1", categories: [ "Kids & Family" ],
                    hints: { comparable_shows: [ "Nonexistent Pod Zzz", "Another Missing Show" ] })
    end

    it "ends needs_input with the unresolved names on the report, never an empty report" do
      report = run(create(:report, show: show, kind: "snapshot"))

      expect(report.status).to eq("needs_input")
      expect(report.finished_at).to be_present
      expect(report.seeds["unresolved"]).to eq([ "Nonexistent Pod Zzz", "Another Missing Show" ])
      expect(report.sponsor_matches).to be_empty
    end

    it "carries nothing forward when the run ends needs_input" do
      create(:report, show: show, kind: "snapshot", status: "done")
      expect(SponsorMatch).not_to receive(:carry_forward!)
      run(create(:report, show: show, kind: "snapshot"))
    end

    it "stays needs_input through the job" do
      report = create(:report, show: show, kind: "snapshot")
      BuildSnapshotJob.perform_now(report.id)
      expect(report.reload.status).to eq("needs_input")
    end
  end

  context "when Qloo rejects our key (Review Focus #4)" do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    before do
      allow(Rails).to receive(:cache).and_return(cache)
      allow_any_instance_of(Taste::Providers::Fake).to receive(:search).and_raise(Taste::AuthError)
    end

    it "fails the report and pauses new runs after three in a row" do
      reports = Array.new(3) { create(:report, show: create(:show, feed_url: "fake://fake-1"), kind: "snapshot") }

      run(reports[0])
      run(reports[1])
      expect(AppSettings.runs_paused?).to be(false)
      run(reports[2])

      expect(reports.map(&:status)).to all(eq("failed"))
      expect(AppSettings.runs_paused?).to be(true)
      expect(AppSettings.get(:runs_paused_reason)).to eq("Qloo authentication failing")
    end

    it "counts failures in a row only: a successful run resets the count" do
      run(create(:report, show: create(:show, feed_url: "fake://fake-1"), kind: "snapshot"))
      run(create(:report, show: create(:show, feed_url: "fake://fake-1"), kind: "snapshot"))
      allow_any_instance_of(Taste::Providers::Fake).to receive(:search).and_call_original
      expect(run(create(:report, show: show, kind: "snapshot")).status).to eq("running")
      allow_any_instance_of(Taste::Providers::Fake).to receive(:search).and_raise(Taste::AuthError)
      run(create(:report, show: create(:show, feed_url: "fake://fake-1"), kind: "snapshot"))

      expect(AppSettings.runs_paused?).to be(false)
    end
  end

  it "lets other Qloo outages fail through the job with the friendly message" do
    report = create(:report, show: show, kind: "snapshot")
    allow_any_instance_of(Taste::Providers::Fake).to receive(:search).and_raise(Taste::Unavailable)
    BuildSnapshotJob.perform_now(report.id)
    expect(report.reload).to have_attributes(status: "failed", error_message: Report::FAILURE_MESSAGE)
  end
end
