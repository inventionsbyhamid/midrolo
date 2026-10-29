require "rails_helper"

RSpec.describe Research::SimilarPodcasts do
  let(:taste) { Taste::Providers::Fake.new }
  let(:show) do
    create(:show, title: "The Founder's Ledger", feed_url: "fake://fake-1", categories: [ "Business", "Finance" ],
                  hints: { comparable_shows: [ "Index Fund Mornings" ], topics: [] })
  end
  let(:report) { create(:report, show: show, kind: "agent", status: "running") }
  let(:toolkit) { Research::Toolkit.new(report, taste: taste, directory: Podcasts::Directories::Fake.new) }
  let(:own_id) { "fake:podcast:the-founder-s-ledger" }
  # What the Fake provider answers for the show itself (deterministic), asked outside any step so it isn't counted.
  let(:qloo_similar) { Taste::Providers::Fake.new.recommend(type: :podcast, entity_ids: [ own_id ], take: 10) }

  def steps = report.agent_steps.reload.map { |step| step.slice(:tool, :status, :output_summary).symbolize_keys }

  def in_catalog(entity, **attrs)
    create(:podcast, :active, title: entity.name, qloo_entity_id: entity.id, **attrs)
  end

  context "when the show is on Qloo (its podcast is linked)" do
    before { show.podcast.update!(qloo_entity_id: own_id) }

    it "asks Qloo once with the show itself and saves the shows, most similar first, never the show" do
      allow(taste).to receive(:recommend).and_call_original
      # The directory has none of the others (the demo directory would add them).
      allow(Catalog::LazyAdd).to receive(:call).and_return(Catalog::LazyAdd::Result.new(found: [], added: []))
      linked = in_catalog(qloo_similar.second)

      entries = described_class.call(toolkit)

      expect(taste).to have_received(:recommend).once.with(type: :podcast, entity_ids: [ own_id ], tag_ids: [], take: 10)
      report.reload
      expect(report.similar_podcasts).to eq(entries)
      expect(entries.size).to eq(10)
      expect(entries.map(&:keys)).to all(eq(%w[qloo_entity_id name score podcast_id])) # build spec section 10
      expect(entries.pluck("qloo_entity_id")).to eq(qloo_similar.map(&:id))
      expect(entries.pluck("qloo_entity_id")).not_to include(own_id)
      expect(entries.pluck("score")).to eq(qloo_similar.map(&:affinity))
      expect(entries.second["podcast_id"]).to eq(linked.id)
      expect(report.taste_calls).to eq(1)
      expect(steps).to eq([ { tool: "similar_podcasts", status: "ok", output_summary: "10 shows: 1 on Midrolo" } ])
      expect(report.agent_steps.first.input_summary).to eq("Your show on Qloo")
    end

    it "never lists the show's own podcast, whatever the catalog matches" do
      allow(Catalog::QlooMatch).to receive(:call).and_return(show.podcast)
      entries = described_class.call(toolkit)
      expect(entries).to be_empty
      expect(steps.first[:output_summary]).to eq("No similar shows came back")
    end

    it "adds a show the catalog lacks through Catalog::LazyAdd and links it to its Qloo entity" do
      first = qloo_similar.first
      other = create(:podcast, title: "#{first.name} Extra")
      added = nil
      # The directory has only the first show; LazyAdd adds it as it answers (before, the catalog lacks it).
      allow(Catalog::LazyAdd).to receive(:call).and_return(Catalog::LazyAdd::Result.new(found: [], added: []))
      allow(Catalog::LazyAdd).to receive(:call).with(first.name) do
        added = create(:podcast, title: first.name, status: "pending")
        Catalog::LazyAdd::Result.new(found: [ other ], added: [ added ])
      end

      entries = described_class.call(toolkit)

      expect(added.reload.qloo_entity_id).to eq(first.id)
      expect(other.reload.qloo_entity_id).to be_nil
      expect(entries.first["podcast_id"]).to eq(added.id)
      expect(Catalog::LazyAdd).to have_received(:call).exactly(10).times
      expect(steps.first[:output_summary]).to eq("10 shows: 1 being added")
    end

    it "won't take a podcast of the same name that belongs to another Qloo entity" do
      first = qloo_similar.first
      taken = create(:podcast, title: first.name, qloo_entity_id: "fake:podcast:someone-else")
      allow(Catalog::LazyAdd).to receive(:call).and_return(Catalog::LazyAdd::Result.new(found: [ taken ], added: []))

      entries = described_class.call(toolkit)
      expect(entries.first["podcast_id"]).to be_nil
      expect(taken.reload.qloo_entity_id).to eq("fake:podcast:someone-else")
    end

    it "adds at most the configured number of shows a run" do
      stub_const("#{described_class}::MAX_ADDS", 2)
      allow(Catalog::LazyAdd).to receive(:call).and_call_original
      allow(Catalog::QlooMatch).to receive(:call).and_call_original
      described_class.call(toolkit)
      expect(Catalog::LazyAdd).to have_received(:call).twice
      # The catalog lookup never reaches the directory itself, so MAX_ADDS bounds the step's outside calls.
      expect(Catalog::QlooMatch).to have_received(:call).with(anything, directory: false).at_least(:once)
      expect(Catalog::QlooMatch).not_to have_received(:call).with(anything)
    end

    it "stops adding once the directory is down, keeping every show and saying so" do
      allow(Catalog::LazyAdd).to receive(:call).and_raise(Podcasts::Directory::Unavailable, "timeout")
      entries = described_class.call(toolkit)

      expect(Catalog::LazyAdd).to have_received(:call).once
      expect(entries.size).to eq(10)
      expect(steps).to eq([ { tool: "similar_podcasts", status: "warning",
                              output_summary: "10 shows: none on Midrolo yet · Stopped adding shows: The podcast directory is unavailable right now." } ])
    end

    it "reports a catalog failure and lists the show without its page instead of failing the report" do
      allow(Catalog::QlooMatch).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "boom")
      expect(Rails.error).to receive(:report).at_least(:once)

      entries = described_class.call(toolkit)
      expect(entries.size).to eq(10)
      expect(entries.pluck("podcast_id")).to all(be_nil)
      expect(steps.first[:status]).to eq("warning")
      expect(steps.first[:output_summary]).to include(described_class::LOOKUP_FAILED)
    end

    it "still asks once the run's soft budget is spent: only the hard ceiling skips it (R130)" do
      toolkit = Research::Toolkit.new(report, taste: taste, max_taste_calls: 0)
      expect(described_class.call(toolkit).size).to eq(10)
    end

    it "skips with a warning, leaving the section as it was, when the hard ceiling refuses the call" do
      report.update!(similar_podcasts: [ { "qloo_entity_id" => "q1", "name" => "Kept", "score" => 0.5, "podcast_id" => nil } ])
      allow(taste).to receive(:recommend).and_raise(Taste::RunBudgetSpent)

      expect(described_class.call(toolkit)).to be_nil
      expect(report.reload.similar_podcasts.pluck("name")).to eq([ "Kept" ])
      expect(steps).to eq([ { tool: "similar_podcasts", status: "warning", output_summary: Research::StepLogger::BUDGET_WARNING } ])
    end

    it "skips with a warning when Qloo is unavailable or rate limited, never failing the run" do
      allow(taste).to receive(:recommend).and_raise(Taste::Unavailable)
      expect(described_class.call(toolkit)).to be_nil
      expect(steps.first).to include(status: "warning", output_summary: "Similar shows skipped: Qloo is unavailable right now.")
    end

    it "lets a Qloo auth error through, as every core call does" do
      allow(taste).to receive(:recommend).and_raise(Taste::AuthError)
      expect { described_class.call(toolkit) }.to raise_error(Taste::AuthError)
      expect(steps.first[:status]).to eq("error")
    end
  end

  describe ".backfill (a report that finished before the step existed)" do
    let(:seeds) do
      { "entities" => [ { "id" => own_id, "name" => "The Founder's Ledger", "type" => "podcast", "source" => Research::Seeds::SHOW_SOURCE },
                        { "id" => "fake:podcast:index-fund-mornings", "name" => "Index Fund Mornings", "type" => "podcast", "source" => "You listed it" } ],
        "tags" => [ { "id" => "urn:tag:genre:media:business", "name" => "Business", "source" => "Show category: Business" } ] }
    end

    before { Taste::Provider.reset! }

    it "runs the step from the seeds the report saved, asking with the show itself when one of them was the show" do
      report.update!(status: "done", seeds: seeds)
      allow(Taste::Provider.current).to receive(:recommend).and_call_original

      entries = described_class.backfill(report)

      expect(Taste::Provider.current).to have_received(:recommend).with(type: :podcast, entity_ids: [ own_id ], tag_ids: [], take: 10)
      expect(entries.size).to eq(10)
      expect(report.reload.similar_podcasts).to eq(entries)
      expect(report.agent_steps.pluck(:tool, :status)).to eq([ %w[similar_podcasts ok] ])
    end

    it "asks with the saved seeds when none of them was the show" do
      seeds["entities"].shift
      report.update!(status: "done", seeds: seeds)
      allow(Taste::Provider.current).to receive(:recommend).and_call_original

      described_class.backfill(report)
      expect(Taste::Provider.current).to have_received(:recommend)
        .with(type: :podcast, entity_ids: [ "fake:podcast:index-fund-mornings" ], tag_ids: [ "urn:tag:genre:media:business" ], take: 10)
    end

    it "does nothing for a report with no seeds" do
      expect(described_class.backfill(report)).to be_nil
      expect(report.agent_steps).to be_empty
    end
  end

  context "when the show isn't on Qloo (a proxy profile)" do
    let(:seed) { taste.search(query: "Index Fund Mornings", types: [ :podcast ]).first }
    let(:tag) { taste.find_tags(query: "Business").first }

    it "asks with the saved seeds instead" do
      toolkit.remember(seed).remember_tags(tag)
      toolkit.seeds = { entities: [ seed ], tags: [ tag ] }
      allow(taste).to receive(:recommend).and_call_original

      entries = described_class.call(toolkit)

      expect(taste).to have_received(:recommend).with(type: :podcast, entity_ids: [ seed.id ], tag_ids: [ tag.id ], take: 10)
      expect(entries.pluck("name")).not_to include("The Founder's Ledger")
      expect(report.agent_steps.first.input_summary).to eq("1 entity and 1 tag seeds")
    end

    it "treats a seed found as the show itself as the show, when its podcast couldn't take the id" do
      own = taste.search(query: "The Founder's Ledger", types: [ :podcast ]).first
      toolkit.record_lookup({ entities: [ own ], tags: [], sources: { own.id => Research::Seeds::SHOW_SOURCE } })
      toolkit.seeds = { entities: [ own, seed ], tags: [] }

      expect(described_class.signals(toolkit)).to eq(entity_ids: [ own.id ], tag_ids: [])
    end

    it "does nothing without seeds" do
      expect(described_class.signals(toolkit)).to be_nil
      expect(described_class.call(toolkit)).to be_nil
      expect(report.agent_steps).to be_empty
    end
  end
end
