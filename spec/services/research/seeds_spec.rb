require "rails_helper"

RSpec.describe Research::Seeds do
  let(:taste) { Taste::Providers::Fake.new }
  let(:hints) { {} }
  let(:categories) { [ "Business" ] }
  let(:title) { "Totally Unknown Indie Show" }
  let(:show) { create(:show, title: title, categories: categories, hints: hints) }
  let(:report) { create(:report, show: show) }
  let(:toolkit) { Research::Toolkit.new(report, taste: taste) }

  describe ".deterministic" do
    context "when the show is not on Qloo and has no hints (Review Focus #1)" do
      it "falls back to the category tag alone" do
        seeds = described_class.deterministic(toolkit)

        expect(seeds[:entities]).to eq([])
        expect(seeds[:tags].map(&:id)).to eq([ "urn:tag:genre:media:business" ])
        expect(seeds[:unresolved]).to eq([])
        expect(seeds[:sources]).to eq("urn:tag:genre:media:business" => "Show category: Business")
      end

      it "skips categories that have no media tag and never raises" do
        show.podcast.update!(categories: [ "Finance", "Kids & Family" ])
        seeds = described_class.deterministic(toolkit)
        expect(seeds).to include(entities: [], tags: [], unresolved: [])
      end

      it "looks categories up among media genre tags only (M4)" do
        allow(taste).to receive(:find_tags).and_call_original
        described_class.deterministic(toolkit)
        expect(taste).to have_received(:find_tags).with(query: "Business", take: 5, types: [ "urn:tag:genre:media" ])
      end
    end

    context "with hints" do
      let(:hints) { { comparable_shows: [ "The Founder's Ledger", "Nonexistent Pod Zzz", "index fund mornings" ], topics: [ "personal finance" ] } }

      it "returns entities for the resolvable hints and lists the rest as unresolved" do
        seeds = described_class.deterministic(toolkit)

        expect(seeds[:entities].map(&:name)).to eq([ "The Founder's Ledger", "Index Fund Mornings" ])
        expect(seeds[:entities].map(&:type)).to all(eq(:podcast))
        expect(seeds[:unresolved]).to eq([ "Nonexistent Pod Zzz" ])
        expect(seeds[:sources].values_at(*seeds[:entities].map(&:id))).to all(eq("You listed it"))
      end

      it "maps topics to tags before categories" do
        seeds = described_class.deterministic(toolkit)

        expect(seeds[:tags].map(&:id)).to eq([ "urn:tag:interest:personal_finance", "urn:tag:genre:media:business" ])
        expect(seeds[:sources]["urn:tag:interest:personal_finance"]).to eq("Topic: personal finance")
      end

      it "caps hint and topic lookups like from_lookup, counting unresolved ones (R31)" do
        show.update_columns(hints: { "comparable_shows" => Array.new(12) { |i| "Zzqx Missing #{i}" },
                                     "topics" => Array.new(7) { |i| "qqzzx#{i}" } })
        allow(taste).to receive(:search).and_call_original
        allow(taste).to receive(:find_tags).and_call_original
        seeds = described_class.deterministic(toolkit)

        expect(taste).to have_received(:search).exactly(1 + described_class::MAX_LOOKUP_NAMES).times
        expect(taste).to have_received(:find_tags).exactly(described_class::MAX_LOOKUP_TOPICS + 1).times # + category
        expect(seeds[:unresolved].size).to eq(described_class::MAX_LOOKUP_NAMES + described_class::MAX_LOOKUP_TOPICS)
      end

      it "keeps at most 5 tag seeds, topics first" do
        show.update!(hints: { topics: [ "personal finance", "remote work", "side projects", "early adopters", "commuting" ] })
        seeds = described_class.deterministic(toolkit)
        expect(seeds[:tags].size).to eq(5)
        expect(seeds[:tags].map(&:id)).not_to include("urn:tag:genre:media:business")
      end

      it "remembers every seed entity for the provenance check" do
        seeds = described_class.deterministic(toolkit)
        expect(toolkit.seen_entity_ids).to include(*seeds[:entities].map(&:id))
      end
    end

    context "when the show itself is on Qloo" do
      let(:title) { "The Founder's Ledger" }
      let(:hints) { { comparable_shows: [ "Founders Ledger", "Dollar Dispatch" ] } }

      it "seeds with the show first and does not repeat it" do
        seeds = described_class.deterministic(toolkit)

        expect(seeds[:entities].map(&:name)).to eq([ "The Founder's Ledger", "Dollar Dispatch" ])
        expect(seeds[:sources][seeds[:entities].first.id]).to eq("Your show on Qloo")
        expect(seeds[:sources][seeds[:entities].last.id]).to eq("You listed it")
      end

      it "logs a friendly step" do
        described_class.deterministic(toolkit)
        step = report.agent_steps.first
        expect(step).to have_attributes(label: "Finding your show on Qloo…", status: "ok")
        expect(step.output_summary).to be_present
        expect(report.reload.taste_calls).to be > 0
      end
    end

    it "lets a Qloo outage propagate so the run fails instead of asking for input" do
      allow(taste).to receive(:search).and_raise(Taste::Unavailable, "down")
      expect { described_class.deterministic(toolkit) }.to raise_error(Taste::Unavailable)
      expect(report.agent_steps.last.status).to eq("error")
    end
  end

  describe ".from_lookup" do
    it "resolves names across entity types and topics to tags" do
      seeds = described_class.from_lookup(toolkit, names: [ "Notion", "Nova Reyes", "Zzqx Nothing" ], topics: [ "remote work", "qqqzzz" ])

      expect(seeds[:entities].map { |e| [ e.name, e.type ] }).to eq([ [ "Notion", :brand ], [ "Nova Reyes", :artist ] ])
      expect(seeds[:tags].map(&:id)).to eq([ "urn:tag:interest:remote_work" ])
      expect(seeds[:unresolved]).to eq([ "Zzqx Nothing", "qqqzzz" ])
      expect(seeds[:sources]).to include("urn:tag:interest:remote_work" => "Topic: remote work")
      expect(toolkit.seen_entity_ids).to include(*seeds[:entities].map(&:id))
    end

    it "labels the show itself and listed hints by source" do
      show.podcast.update!(title: "Dollar Dispatch")
      show.update!(hints: { comparable_shows: [ "Shipping Soon" ] })
      seeds = described_class.from_lookup(toolkit, names: [ "Dollar Dispatch", "Shipping Soon", "Notion" ], topics: [])

      expect(seeds[:sources].values).to eq([ "Your show on Qloo", "You listed it", "Matched \"Notion\"" ])
    end

    it "links the show's podcast to the Qloo entity found for the show itself" do
      show.podcast.update!(title: "Dollar Dispatch")
      seeds = described_class.from_lookup(toolkit, names: [ "Dollar Dispatch", "Notion" ], topics: [])

      own = seeds[:entities].find { |entity| entity.name == "Dollar Dispatch" }
      expect(show.podcast.reload.qloo_entity_id).to eq(own.id)
    end

    it "ignores blanks and duplicates" do
      seeds = described_class.from_lookup(toolkit, names: [ "Notion", " ", "notion" ], topics: [ "" ])
      expect(seeds[:entities].map(&:name)).to eq([ "Notion" ])
      expect(seeds[:unresolved]).to eq([])
    end
  end
end
