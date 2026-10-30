require "rails_helper"

RSpec.describe Sponsors::ScanJob do
  context "in fake LLM mode (the pattern scan stands in)" do
    before { allow(Llm).to receive(:mode).and_return(:fake) }

    it "finds and saves the sponsor reads in a podcast's new episodes" do
      podcast, episode = podcast_from_fixture("sponsor_block")
      plain = create(:episode, podcast: podcast, description: "No sponsors this week.")

      described_class.perform_now(podcast.id, [ episode.id, plain.id ])

      expect(Sponsors::History.for(podcast).map { |row| row.brand.name }).to contain_exactly("Encord", "Notion", "LMNT", "AG1")
      expect(Brand.find_by!(domain: "drinklmnt.com")).to have_attributes(name: "LMNT", sponsor_mentions_count: 1)
      expect([ episode.reload.sponsor_scanned_at, plain.reload.sponsor_scanned_at ]).to all(be_present)
      expect([ episode.sponsor_ai_checked_at, plain.sponsor_ai_checked_at ]).to all(be_nil)
    end

    it "is idempotent, and skips episodes already scanned unless asked to rescan" do
      podcast, episode = podcast_from_fixture("host_reads")
      described_class.perform_now(podcast.id, [ episode.id ])
      allow(Sponsors::Scan).to receive(:call).and_call_original

      expect { described_class.perform_now(podcast.id, [ episode.id ]) }.not_to change(SponsorMention, :count)
      expect(Sponsors::Scan).not_to have_received(:call)

      expect { described_class.perform_now(podcast.id, [ episode.id ], rescan: true) }.not_to change(SponsorMention, :count)
      expect(Sponsors::Scan).to have_received(:call).once
      expect(Brand.where(name: %w[AG1 Shopify]).pluck(:sponsor_mentions_count)).to eq([ 1, 1 ])
    end

    it "never scans a removed, inactive or missing podcast, or another podcast's episodes" do
      podcast, episode = podcast_from_fixture("host_reads")
      other, = podcast_from_fixture("inline_list")
      dormant, old = podcast_from_fixture("weak_hints")
      dormant.update!(status: "dormant")
      allow(Sponsors::Scan).to receive(:call)

      described_class.perform_now(other.id, [ episode.id ])
      described_class.perform_now(0, [ episode.id ])
      described_class.perform_now(dormant.id, [ old.id ])
      podcast.update!(status: "removed")
      described_class.perform_now(podcast.id, [ episode.id ])

      expect(Sponsors::Scan).not_to have_received(:call)
    end

    it "is queued by the podcast for its due episodes" do
      podcast, episode = podcast_from_fixture("host_reads")
      create(:episode, podcast: podcast, sponsor_scanned_at: 1.day.ago)
      create(:episode, podcast: podcast, published_at: 60.days.ago)

      expect { podcast.scan_sponsors_later }.to have_enqueued_job(described_class).with(podcast.id, [ episode.id ], rescan: false)
        .on_queue("sponsors").at_priority(20)
      expect { create(:podcast).scan_sponsors_later }.not_to have_enqueued_job(described_class)
    end
  end

  context "with the model" do
    let(:podcast) { create(:podcast, :active, title: "Bench Notes", author: "Kim Ode") }
    let(:notes) { "Planes, saws and the glue debate. This episode is brought to you by Hollow Tools. Go to hollowtools.com/bench." }

    def episode(days_ago = 2, **attributes)
      create(:episode, **{ podcast: podcast, description: notes, published_at: days_ago.days.ago }.merge(attributes))
    end

    # How many episodes the model was sent, call by call.
    def sent = RubyLLM::Test.requests.map { |request| request[:messages].last.content.to_s.scan(/^Episode (e\d+) notes/).flatten.size }

    def confirm(*refs)
      { mentions: refs.map do |ref|
        { episode_ref: ref, brand: "Hollow Tools", domain: "hollowtools.com", promo_code: "", offer: "",
          evidence: "This episode is brought to you by Hollow Tools.", is_sponsor: true, confidence: 0.9 }
      end }
    end

    before do
      allow(Llm).to receive(:mode).and_return(:live)
      @old_key = RubyLLM.config.openrouter_api_key
      RubyLLM.config.openrouter_api_key = "test-key"
    end

    after { RubyLLM.config.openrouter_api_key = @old_key }

    it "sends a recent episode and marks it checked; an older one is never sent and stays unscanned" do
      recent = episode(2)
      old = episode(40)
      RubyLLM::Test.stub_response(confirm("e1"))

      described_class.perform_now(podcast.id, [ recent.id, old.id ])

      expect(sent).to eq([ 1 ])
      expect(recent.reload).to have_attributes(sponsor_ai_checked_at: be_present, sponsor_scanned_at: be_present)
      expect(old.reload).to have_attributes(sponsor_ai_checked_at: nil, sponsor_scanned_at: nil)
      expect(SponsorMention.sole).to have_attributes(episode_id: recent.id, detected_by: "llm")
    end

    it "reaches older episodes when sponsors_ai_window_days is widened" do
      old = episode(40)
      AppSettings.set(:sponsors_ai_window_days, 60)
      RubyLLM::Test.stub_response(confirm("e1"))

      described_class.perform_now(podcast.id, [ old.id ])

      expect(sent).to eq([ 1 ])
      expect(old.reload.sponsor_ai_checked_at).to be_present
    end

    it "never sends a checked episode again, but gives one only an older pattern scan read its single check" do
      checked = episode(3, sponsor_scanned_at: 3.days.ago, sponsor_ai_checked_at: 3.days.ago)
      kept = create(:sponsor_mention, episode: checked, podcast: podcast, detected_by: "llm")
      patterned = episode(2, sponsor_scanned_at: 2.days.ago)
      create(:sponsor_mention, episode: patterned, podcast: podcast, brand: create(:brand, name: "Mercury"), detected_by: "pattern")
      RubyLLM::Test.stub_response(confirm("e1"))

      described_class.perform_now(podcast.id, [ checked.id, patterned.id ])
      described_class.perform_now(podcast.id, [ checked.id, patterned.id ])

      expect(sent).to eq([ 1 ])
      expect(kept.reload).to be_present
      expect(SponsorMention.where(episode: patterned).map { |m| [ m.brand.name, m.detected_by ] }).to eq([ [ "Hollow Tools", "llm" ] ])
      expect(patterned.reload.sponsor_ai_checked_at).to be_present
    end

    it "takes at most sponsors_max_per_podcast episodes a run, the newest first" do
      episodes = (1..12).map { |days| episode(days) }
      RubyLLM::Test.stub_responses({ mentions: [] }, { mentions: [] })

      described_class.perform_now(podcast.id, episodes.map(&:id))
      expect(sent).to eq([ 10 ])
      expect(episodes.map { |e| e.reload.sponsor_ai_checked_at.present? }).to eq([ true ] * 10 + [ false ] * 2)

      AppSettings.set(:sponsors_max_per_podcast, 1)
      described_class.perform_now(podcast.id, episodes.map(&:id))
      expect(sent).to eq([ 10, 1 ])
      expect(episodes[10].reload.sponsor_ai_checked_at).to be_present
    end

    it "does nothing at all while the catalog budget is 0" do
      AppSettings.set(:llm_catalog_daily_usd, 0)
      due = episode(2)
      short = episode(2, description: "Short.")

      described_class.perform_now(podcast.id, [ due.id, short.id ])

      expect(RubyLLM::Test.requests).to be_empty
      expect([ due, short ].map(&:reload)).to all(have_attributes(sponsor_ai_checked_at: nil, sponsor_scanned_at: nil))
    end

    it "gives a new brand its proper name and never renames an existing one" do
      notion = create(:brand, name: "Notion Labs", domain: "notion.so")
      first = episode(2, description: "Rebounders and knees today. Big thanks to the folks at cellercise.com for making this one happen.")
      second = episode(3, description: "Our planning setup, start to finish. Brought to you by Notion. Try it at notion.so/bench today.")
      RubyLLM::Test.stub_response({ mentions: [
        { episode_ref: "e1", brand: "Cellercise", domain: "cellercise.com", promo_code: "", offer: "", evidence: "",
          is_sponsor: true, confidence: 0.9 },
        { episode_ref: "e2", brand: "Notion", domain: "notion.so", promo_code: "", offer: "", evidence: "",
          is_sponsor: true, confidence: 0.9 }
      ] })

      described_class.perform_now(podcast.id, [ first.id, second.id ])

      expect(Brand.find_by!(domain: "cellercise.com").name).to eq("Cellercise")
      expect(notion.reload.name).to eq("Notion Labs")
      expect(SponsorMention.find_by!(episode: second).brand).to eq(notion)
    end

    it "rescans on an admin's request, checked episodes too, replacing their mentions without duplicates" do
      done = episode(2, sponsor_scanned_at: 2.days.ago, sponsor_ai_checked_at: 2.days.ago)
      RubyLLM::Test.stub_responses(confirm("e1"), confirm("e1"))

      2.times { described_class.perform_now(podcast.id, [ done.id ], rescan: true) }

      expect(sent).to eq([ 1, 1 ])
      expect(SponsorMention.where(episode: done).count).to eq(1)
      expect(Brand.find_by!(domain: "hollowtools.com").sponsor_mentions_count).to eq(1)
    end
  end
end
