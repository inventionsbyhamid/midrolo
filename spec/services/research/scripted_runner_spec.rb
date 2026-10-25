require "rails_helper"

RSpec.describe Research::ScriptedRunner do
  let(:show) do
    create(:show, title: "The Founder's Ledger", feed_url: "fake://fake-1", categories: [ "Business", "Finance" ],
                  downloads_per_episode: 1500, hints: { comparable_shows: [ "Index Fund Mornings" ], topics: [] })
  end

  before do
    Taste::Provider.reset!
    Podcasts::Directory.reset!
  end

  context "with reasons (full report on Fake providers)" do
    let(:report) { create(:report, show: show, kind: "agent", status: "running") }

    it "fills every section with 20–50 reasoned matches and a summary, every step ok" do
      described_class.call(report, with_reasons: true)
      report.reload

      expect(report.seeds["entities"].pluck("name")).to include("The Founder's Ledger", "Index Fund Mornings")
      expect(report.profile_kind).to eq("direct")
      expect(report.audience.keys).to match_array(%w[brands artists tv_shows podcasts tags])
      expect(report.demographics.keys).to match_array(%w[age gender])
      expect(report.heatmap["points"]).to be_present
      expect(report.sponsor_matches.size).to be_between(20, 50)
      expect(report.sponsor_matches.map(&:reason)).to all(be_present)
      reasons = report.sponsor_matches.map(&:reason)
      expect(reasons.map(&:length)).to all(be <= SponsorMatch::REASON_LENGTH)
      expect(reasons.map { |reason| reason.split.size }).to all(be <= SponsorMatch::REASON_WORDS) # R99
      expect(reasons).to all(match(/\A[^.!?]+[.!?]\z/)) # one sentence
      expect(report.sponsor_matches.first.reason).to match(/\A.+ fans share this audience's love of .+\.\z/)
      expect(report.sponsor_matches.map(&:brand_description)).to all(start_with("Sample ")) # R52, from the Fake catalog
      points = report.summary_points
      expect(points.size).to be_between(2, Report::SUMMARY_POINTS)
      expect(points.map { |point| point.split.size }).to all(be <= Report::SUMMARY_POINT_WORDS) # R99
      expect(points.first).to start_with("This audience leans toward")
      expect(report.agent_steps.pluck(:status)).to all(eq("ok"))
      expect(report.taste_calls).to be_positive
      expect(report.status).to eq("running") # the job marks it done
    end

    it "searches the brand categories mapped from the show's categories" do
      allow(Research::SponsorCandidates).to receive(:find).and_call_original
      described_class.call(report, with_reasons: true)
      expect(Research::SponsorCandidates).to have_received(:find)
        .with(anything, hash_including(categories: [ "Finance", "Productivity", "Technology" ], scan_limit: 8))
    end

    it "never touches the LLM" do
      expect(RubyLLM).not_to receive(:chat)
      expect(Llm::Budget).not_to receive(:record!)
      described_class.call(report, with_reasons: true)
    end
  end

  context "without reasons (snapshot)" do
    let(:report) { create(:report, show: show, kind: "snapshot", status: "running") }

    it "saves only taste tags, the map and unreasoned matches, with no demographics, proven scan or summary" do
      expect(Research::ProvenSponsorScan).to receive(:new).with(anything, hash_including(limit: 0)).and_call_original
      described_class.call(report, with_reasons: false)
      report.reload

      expect(report.audience.keys).to eq([ "tags" ])
      expect(report.audience["tags"]).to be_present
      expect(report.demographics).to be_nil
      expect(report.heatmap["points"]).to be_present
      expect(report.sponsor_matches.size).to be_between(20, 50)
      expect(report.sponsor_matches.map(&:reason)).to all(be_nil)
      expect(report.sponsor_matches.map(&:brand_description)).to all(be_present)
      expect(report.sponsor_matches.map(&:fit_score)).to all(be_present)
      expect(report.summary).to be_nil
      expect(report.agent_steps.pluck(:tool)).not_to include("demographics", "proven_sponsor_scan", "explain_matches")
    end
  end

  context "when no sponsor candidates come back (Review Focus #1)" do
    let(:report) { create(:report, show: show, kind: "snapshot", status: "running") }

    it "raises NeedsInput instead of finishing with an empty list" do
      allow(Research::SponsorCandidates).to receive(:find).and_return([])
      expect { described_class.call(report, with_reasons: false) }.to raise_error(Research::NeedsInput)
      expect(report.reload.seeds).to be_present
      expect(report.sponsor_matches).to be_empty
    end
  end

  context "when fewer than 2 seeds are found (Review Focus #1)" do
    let(:show) { create(:show, title: "Totally Unknown Indie Show", feed_url: "fake://fake-1", categories: [ "Kids & Family" ], hints: { comparable_shows: [ "Nonexistent Pod Zzz" ] }) }
    let(:report) { create(:report, show: show, kind: "snapshot", status: "running") }

    it "saves the seeds with the unresolved names and raises NeedsInput before any profile work" do
      expect { described_class.call(report, with_reasons: false) }.to raise_error(Research::NeedsInput)
      report.reload
      expect(report.seeds["unresolved"]).to eq([ "Nonexistent Pod Zzz" ])
      expect(report.audience).to be_nil
      expect(report.sponsor_matches).to be_empty
    end
  end
end
