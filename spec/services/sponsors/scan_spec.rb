require "rails_helper"

RSpec.describe Sponsors::Scan do
  def summary(result) = result.detections.map { |d| [ d.name, d.domain, d.detected_by ] }

  def mention(ref, brand, sponsor: true, confidence: 0.9, **fields)
    { episode_ref: ref, brand: brand, domain: "", promo_code: "", offer: "", evidence: "", is_sponsor: sponsor,
      confidence: confidence }.merge(fields)
  end

  def prompt_of(request) = request[:messages].map { |message| message.content.to_s }.join("\n")

  context "in fake LLM mode" do
    before { allow(Llm).to receive(:mode).and_return(:fake) }

    it "keeps the strong pattern reads, drops the hints, and marks every episode read but none checked, with no call" do
      podcast, episode = podcast_from_fixture("host_reads")
      weak = create(:episode, podcast: podcast, description: sponsor_fixture("weak_hints").notes)
      plain = create(:episode, podcast: podcast, description: "A quiet episode about lathes.")

      result = described_class.call(podcast, [ episode, weak, plain ])

      expect(summary(result)).to eq([ [ "AG1", "drinkag1.com", "pattern" ], [ "Shopify", "shopify.com", "pattern" ],
                                      [ "Helix Sleep", "helixsleep.com", "pattern" ] ])
      expect(result.detections.map(&:episode)).to all(eq(episode))
      expect(result.detections.last).to have_attributes(promo_code: "TIM", offer: "20% off all mattress orders", confidence: 0.9)
      expect(result).to have_attributes(stage2: :fake, checked_episode_ids: [], settled_episode_ids: [])
      expect(result.scanned_episode_ids).to contain_exactly(episode.id, weak.id, plain.id)
      expect(RubyLLM::Test.requests).to be_empty
    end

    describe "recurrence" do
      let(:podcast) { create(:podcast, title: "Bench Notes", author: "Kim Ode") }

      it "adds confidence to a read that recurs over a month" do
        episodes = [ 70, 40, 5 ].map do |days|
          create(:episode, podcast: podcast, published_at: days.days.ago,
                           description: "Dovetails by hand. This episode is brought to you by Hollow Tools. Go to hollowtools.com/bench.")
        end

        detections = described_class.call(podcast, [ episodes.last ]).detections
        expect(detections.map(&:confidence)).to eq([ 0.95 ])
      end

      it "leaves a code in nearly every episode's footer to the model" do
        footer = "Get 10% off cedar planters at cedarbox.com with code BENCH."
        episodes = Array.new(7) do |i|
          create(:episode, podcast: podcast, published_at: (i * 7).days.ago,
                           description: "Episode #{i}: we cut tenons by hand and talk glue.\n#{footer}")
        end

        expect(described_class.call(podcast, episodes.first(2)).detections).to be_empty
      end
    end
  end

  context "with the model" do
    before do
      allow(Llm).to receive(:mode).and_return(:live)
      @old_key = RubyLLM.config.openrouter_api_key
      RubyLLM.config.openrouter_api_key = "test-key"
    end

    after { RubyLLM.config.openrouter_api_key = @old_key }

    it "sends every episode with enough notes, hint or not, with the pattern candidates only as hints, and skips short notes" do
      podcast, episode = podcast_from_fixture("weak_hints")
      plain = create(:episode, podcast: podcast,
                               description: "Stout yeast, roast levels and why barrel aging takes years. Then a long round of listener mail.")
      short = create(:episode, podcast: podcast, description: "Short one.")
      RubyLLM::Test.stub_response({ mentions: [
        mention("e1", "Athletic Brewing", domain: "athleticbrewing.com", offer: "20% off your first order",
                                          evidence: "Check out Athletic Brewing at athleticbrewing.com for 20% off your first order."),
        mention("e1", "Wealthfront", confidence: 0.55)
      ] })

      result = nil
      expect { result = described_class.call(podcast, [ episode, plain, short ]) }.to change(SpendEntry.where(bucket: "catalog"), :count).by(1)

      expect(summary(result)).to eq([ [ "Athletic Brewing", "athleticbrewing.com", "llm" ] ])
      expect(result.detections.first).to have_attributes(offer: "20% off your first order", confidence: 0.9,
                                                         url: "https://athleticbrewing.com",
                                                         evidence: "Check out Athletic Brewing at athleticbrewing.com for 20% off your first order.")
      expect(result).to have_attributes(stage2: :done, checked_episode_ids: contain_exactly(episode.id, plain.id),
                                        settled_episode_ids: contain_exactly(episode.id, plain.id, short.id),
                                        scanned_episode_ids: contain_exactly(episode.id, plain.id, short.id))
      expect(SpendEntry.last).to have_attributes(model: Llm.sponsors_model, user_id: nil)
      expect(Llm.sponsors_model).to eq("z-ai/glm-5.3-flash")

      request = RubyLLM::Test.last_request
      prompt = prompt_of(request)
      expect(prompt).to include("Show: <untrusted_feed>Brew Notes by Ana Ruiz</untrusted_feed>")
      expect(prompt).to include("Episode e1 notes:\n<untrusted_feed>\nWe taste three winter stouts. Presented by Wealthfront.\n" \
                                "Check out Athletic Brewing at athleticbrewing.com for 20% off your first order.\n</untrusted_feed>")
      expect(prompt).to include("Hints for e1: <untrusted_feed>Wealthfront; Athletic Brewing (athleticbrewing.com)</untrusted_feed>")
      expect(prompt).to include("Episode e2 notes:\n<untrusted_feed>\nStout yeast")
      expect(prompt).not_to include("Hints for e2", "Short one", "Episode e3")
      expect(request[:temperature]).to be_nil
    end

    it "finds a sponsor the patterns can't see, by its proper name" do
      podcast = create(:podcast, title: "Bounce Back", author: "Lee Park")
      episode = create(:episode, podcast: podcast,
                                 description: "Big thanks to the folks at cellercise.com for making this one happen. We talk knees and rebounders.")
      expect(Sponsors::Notes.new(episode.description, Sponsors::Context.for(podcast)).candidates).to be_empty
      RubyLLM::Test.stub_response({ mentions: [
        mention("e1", "Cellercise", domain: "cellercise.com", evidence: "Big thanks to the folks at cellercise.com for making this one happen.")
      ] })

      result = described_class.call(podcast, [ episode ])

      expect(summary(result)).to eq([ [ "Cellercise", "cellercise.com", "llm" ] ])
      expect(result.detections.first).to have_attributes(url: "https://cellercise.com",
                                                         evidence: "Big thanks to the folks at cellercise.com for making this one happen.")
    end

    it "takes the model's answer as final: a strong pattern read it doesn't confirm is dropped" do
      podcast, episode = podcast_from_fixture("inline_list")
      RubyLLM::Test.stub_response({ mentions: [
        mention("e1", "Notion", domain: "notion.com", evidence: "Notion (notion.com/hardreset)"),
        mention("e1", "Ramp", sponsor: false)
      ] })

      result = described_class.call(podcast, [ episode ])

      expect(summary(result)).to eq([ [ "Notion", "notion.com", "llm" ] ])
      expect(result.detections.first.url).to eq("https://notion.com/hardreset")
    end

    it "never takes what the notes don't say: invented brands, codes, offers and quotes, platforms and the show itself" do
      podcast, episode = podcast_from_fixture("weak_hints")
      RubyLLM::Test.stub_response({ mentions: [
        mention("e1", "Athletic Brewing", promo_code: "BREW50", offer: "Half off everything", evidence: "Athletic Brewing is great"),
        mention("e1", "Liquid Death", domain: "liquiddeath.com"),
        mention("e1", "Patreon"),
        mention("e1", "Brew Notes"),
        mention("e7", "Wealthfront")
      ] })

      detections = described_class.call(podcast, [ episode ]).detections

      expect(detections.map(&:name)).to eq([ "Athletic Brewing" ])
      expect(detections.first).to have_attributes(promo_code: nil, offer: "20% off your first order",
                                                   evidence: "Check out Athletic Brewing at athleticbrewing.com for 20% off your first order.")
    end

    it "sends at most ten episodes a call" do
      podcast = create(:podcast, title: "Lathe Talk")
      episodes = Array.new(12) do |i|
        create(:episode, podcast: podcast, description: "Episode #{i} on bowl gouges, sharpening jigs and green wood. This episode is sponsored by Hollow Tools.")
      end
      RubyLLM::Test.stub_responses({ mentions: [] }, { mentions: [] })

      result = described_class.call(podcast, episodes)

      expect(RubyLLM::Test.requests.size).to eq(2)
      expect(result.checked_episode_ids).to match_array(episodes.map(&:id))
      expect(result.detections).to be_empty # the model confirmed none
    end

    it "makes no call, saves nothing and settles no episode with notes when the catalog budget is spent" do
      AppSettings.set(:llm_catalog_daily_usd, 0)
      podcast, episode = podcast_from_fixture("host_reads")

      result = described_class.call(podcast, [ episode ])

      expect(RubyLLM::Test.requests).to be_empty
      expect(result).to have_attributes(stage2: :budget, detections: [], checked_episode_ids: [], settled_episode_ids: [],
                                        scanned_episode_ids: [])
    end

    # Review M2: a later batch's failure keeps what an earlier batch's paid answer found, and never marks its own.
    it "keeps the first batch's answer and leaves the second batch due, mentions intact, when the second call fails" do
      podcast = create(:podcast, :active, title: "Lathe Talk")
      episodes = Array.new(12) do |i|
        create(:episode, podcast: podcast,
                         description: "Episode #{i} on bowl gouges and green wood. This episode is brought to you by Hollow Tools. " \
                                      "Go to hollowtools.com/lathe.")
      end
      kept = episodes.last(2).map do |episode|
        create(:sponsor_mention, episode: episode, podcast: podcast, brand: create(:brand, name: "Old Read #{episode.id}"))
      end
      replaced = create(:sponsor_mention, episode: episodes.first, podcast: podcast, brand: create(:brand, name: "Gone"))
      RubyLLM::Test.stub_response({ mentions: [ mention("e1", "Hollow Tools", domain: "hollowtools.com") ] })
      calls = 0
      allow(Sponsors::LlmCheck).to receive(:call).and_wrap_original do |original, *args|
        calls += 1
        raise Faraday::TimeoutError if calls == 2

        original.call(*args)
      end
      allow(Rails.error).to receive(:report)

      result = described_class.call(podcast, episodes)
      Sponsors::Record.call(podcast, result)

      expect(result).to have_attributes(stage2: :failed, checked_episode_ids: episodes.first(10).map(&:id),
                                        settled_episode_ids: episodes.first(10).map(&:id))
      expect(episodes.last(2).map { |e| e.reload.sponsor_ai_checked_at }).to all(be_nil)
      expect(kept.map { |m| m.reload.present? }).to all(be(true))
      expect(SponsorMention.exists?(replaced.id)).to be(false)
      expect(SponsorMention.where(episode: episodes.first).map { |m| m.brand.domain }).to eq([ "hollowtools.com" ])
      expect(Rails.error).to have_received(:report).with(an_instance_of(Faraday::TimeoutError), hash_including(handled: true))
    end

    it "leaves the batch due with its pattern reads when the reply isn't the schema's shape (review H1)" do
      podcast, episode = podcast_from_fixture("host_reads")
      pattern = create(:sponsor_mention, episode: episode, podcast: podcast, brand: create(:brand, name: "AG1", domain: "drinkag1.com"))
      RubyLLM::Test.stub_response({ items: [ mention("e1", "Shopify", domain: "shopify.com") ] })
      allow(Rails.error).to receive(:report)

      result = nil
      expect { result = described_class.call(podcast, [ episode ]) }.to change(SpendEntry, :count).by(1)
      Sponsors::Record.call(podcast, result)

      expect(result).to have_attributes(stage2: :failed, checked_episode_ids: [], settled_episode_ids: [], detections: [])
      expect(pattern.reload).to be_present
      expect(episode.reload).to have_attributes(sponsor_ai_checked_at: nil, sponsor_scanned_at: nil)
      expect(Rails.error).to have_received(:report).with(a_kind_of(Llm::Error), hash_including(handled: true))
    end

    describe "a reply that can't be read (split fix)" do
      let(:podcast) { create(:podcast, :active, title: "Lathe Talk") }
      let(:episodes) do
        Array.new(10) do |i|
          create(:episode, podcast: podcast,
                           description: "Episode #{i} on bowl gouges and green wood. This episode is brought to you by " \
                                        "Hollow Tools. Go to hollowtools.com/lathe.")
        end
      end
      let(:cut_off) { '{"mentions": [{"episode_ref": "e1", "brand": "Hollow To' }

      def confirm(count) = { mentions: (1..count).map { |i| mention("e#{i}", "Hollow Tools", domain: "hollowtools.com") } }

      before { allow(Rails.error).to receive(:report) }

      it "splits a cut-off batch in halves and checks each, with every call's spend recorded" do
        RubyLLM::Test.stub_responses(cut_off, confirm(5), confirm(5))

        result = nil
        expect { result = described_class.call(podcast, episodes) }.to change(SpendEntry.where(bucket: "catalog"), :count).by(3)

        expect(RubyLLM::Test.requests.size).to eq(3)
        expect(result).to have_attributes(stage2: :done, checked_episode_ids: match_array(episodes.map(&:id)),
                                          settled_episode_ids: match_array(episodes.map(&:id)))
        expect(result.detections.map(&:episode)).to match_array(episodes)
        expect(Rails.error).not_to have_received(:report)
      end

      it "leaves an episode whose reply is cut off even alone due, and checks the rest" do
        stuck, fine = episodes.first(2)
        RubyLLM::Test.stub_responses(cut_off, cut_off, confirm(1))

        result = described_class.call(podcast, [ stuck, fine ])
        Sponsors::Record.call(podcast, result)

        expect(RubyLLM::Test.requests.size).to eq(3)
        expect(result).to have_attributes(stage2: :failed, checked_episode_ids: [ fine.id ])
        expect(stuck.reload).to have_attributes(sponsor_ai_checked_at: nil, sponsor_scanned_at: nil)
        expect(fine.reload.sponsor_ai_checked_at).to be_present
        expect(Rails.error).to have_received(:report).with(an_instance_of(JSON::ParserError), hash_including(handled: true)).once
      end

      it "leaves a single episode's cut-off reply due after one call" do
        RubyLLM::Test.stub_response(cut_off)

        result = described_class.call(podcast, episodes.first(1))

        expect(RubyLLM::Test.requests.size).to eq(1)
        expect(result).to have_attributes(stage2: :failed, checked_episode_ids: [], settled_episode_ids: [])
      end

      it "splits a batch whose reply names none of its episodes, as for a cut-off reply" do
        RubyLLM::Test.stub_responses({ mentions: [ mention("x1", "Hollow Tools") ] }, confirm(5), confirm(5))

        result = described_class.call(podcast, episodes)

        expect(RubyLLM::Test.requests.size).to eq(3)
        expect(result).to have_attributes(stage2: :done, checked_episode_ids: match_array(episodes.map(&:id)))
      end

      it "doesn't split on a provider error" do
        allow(Sponsors::LlmCheck).to receive(:call).and_raise(Faraday::TimeoutError)

        result = described_class.call(podcast, episodes)

        expect(Sponsors::LlmCheck).to have_received(:call).once
        expect(result).to have_attributes(stage2: :failed, checked_episode_ids: [])
      end

      it "stops splitting when the budget says no" do
        RubyLLM::Test.stub_responses(cut_off, confirm(5))
        allow(Llm::Budget).to receive(:allow?).and_return(true, true, false)

        result = described_class.call(podcast, episodes)

        expect(RubyLLM::Test.requests.size).to eq(1)
        expect(result).to have_attributes(stage2: :budget, checked_episode_ids: [])
      end
    end

    it "saves nothing and leaves the episodes due when the provider fails" do
      podcast, episode = podcast_from_fixture("host_reads")
      allow(Sponsors::LlmCheck).to receive(:call).and_raise(Faraday::TimeoutError)
      allow(Rails.error).to receive(:report)

      result = described_class.call(podcast, [ episode ])

      expect(result).to have_attributes(stage2: :failed, detections: [], scanned_episode_ids: [], settled_episode_ids: [])
      expect(Rails.error).to have_received(:report).with(an_instance_of(Faraday::TimeoutError), hash_including(handled: true))
    end
  end
end
