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
