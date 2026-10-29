require "rails_helper"

RSpec.describe Sponsors::Scan do
  def summary(result) = result.detections.map { |d| [ d.name, d.domain, d.detected_by ] }

  def mention(ref, brand, sponsor: true, confidence: 0.9, **fields)
    { episode_ref: ref, brand: brand, domain: "", promo_code: "", offer: "", evidence: "", is_sponsor: sponsor,
      confidence: confidence }.merge(fields)
  end

  context "in fake LLM mode" do
    before { allow(Llm).to receive(:mode).and_return(:fake) }

    it "keeps the strong pattern reads, drops the hints, and marks every episode scanned without a model call" do
      podcast, episode = podcast_from_fixture("host_reads")
      weak = create(:episode, podcast: podcast, description: sponsor_fixture("weak_hints").notes)
      plain = create(:episode, podcast: podcast, description: "A quiet episode about lathes.")

      result = described_class.call(podcast, [ episode, weak, plain ])

      expect(summary(result)).to eq([ [ "AG1", "drinkag1.com", "pattern" ], [ "Shopify", "shopify.com", "pattern" ],
                                      [ "Helix Sleep", "helixsleep.com", "pattern" ] ])
      expect(result.detections.map(&:episode)).to all(eq(episode))
      expect(result.detections.last).to have_attributes(promo_code: "TIM", offer: "20% off all mattress orders", confidence: 0.9)
      expect(result.stage2).to eq(:fake)
      expect(result.checked_episode_ids).to be_empty
      expect(result.scanned_episode_ids).to contain_exactly(episode.id, weak.id, plain.id)
      expect(RubyLLM::Test.requests).to be_empty
    end

    it "says no model was needed when no episode has a candidate" do
      podcast = create(:podcast)
      episode = create(:episode, podcast: podcast, description: "Nothing to see. Follow us on instagram.com/x.")

      expect(described_class.call(podcast, [ episode ])).to have_attributes(detections: [], stage2: :not_needed,
                                                                             scanned_episode_ids: [ episode.id ])
    end

    describe "recurrence" do
      let(:podcast) { create(:podcast, title: "Bench Notes", author: "Kim Ode") }

      it "adds confidence to a read that recurs over a month" do
        episodes = [ 70, 40, 5 ].map do |days|
          create(:episode, podcast: podcast, published_at: days.days.ago,
                           description: "This episode is brought to you by Hollow Tools. Go to hollowtools.com/bench.")
        end

        detections = described_class.call(podcast, [ episodes.last ]).detections
        expect(detections.map(&:confidence)).to eq([ 0.95 ])
      end

      it "leaves a code in nearly every episode's footer to the model" do
        footer = "Get 10% off cedar planters at cedarbox.com with code BENCH."
        episodes = Array.new(7) { |i| create(:episode, podcast: podcast, published_at: (i * 7).days.ago, description: "Episode #{i}.\n#{footer}") }

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

    it "checks candidate episodes on the cheap model, from the catalog bucket, with the notes marked untrusted" do
      podcast, episode = podcast_from_fixture("weak_hints")
      RubyLLM::Test.stub_response({ mentions: [
        mention("e1", "Athletic Brewing", domain: "athleticbrewing.com", offer: "20% off your first order",
                                          evidence: "Check out Athletic Brewing at athleticbrewing.com for 20% off your first order."),
        mention("e1", "Wealthfront", confidence: 0.55)
      ] })

      result = nil
      expect { result = described_class.call(podcast, [ episode ]) }.to change(SpendEntry.where(bucket: "catalog"), :count).by(1)

      expect(summary(result)).to eq([ [ "Athletic Brewing", "athleticbrewing.com", "llm" ] ])
      expect(result.detections.first).to have_attributes(offer: "20% off your first order", confidence: 0.9,
                                                         url: "https://athleticbrewing.com",
                                                         evidence: "Check out Athletic Brewing at athleticbrewing.com for 20% off your first order.")
      expect(result).to have_attributes(stage2: :done, checked_episode_ids: [ episode.id ], scanned_episode_ids: [ episode.id ])
      expect(SpendEntry.last).to have_attributes(model: Llm.cheap_model, user_id: nil)
      request = RubyLLM::Test.last_request
      prompt = request[:messages].map { |message| message.content.to_s }.join("\n")
      expect(prompt).to include("Show: <untrusted_feed>Brew Notes by Ana Ruiz</untrusted_feed>", "Candidates for e1")
      expect(prompt).to include("Episode e1 notes: <untrusted_feed>Presented by Wealthfront. ... Check out Athletic Brewing")
      expect(request[:temperature]).to be_nil
    end

    it "lets the model reject a pattern read, and keeps strong reads it said nothing about" do
      podcast, episode = podcast_from_fixture("inline_list")
      RubyLLM::Test.stub_response({ mentions: [
        mention("e1", "Notion", domain: "notion.com", evidence: "Notion (notion.com/hardreset)"),
        mention("e1", "Ramp", sponsor: false)
      ] })

      result = described_class.call(podcast, [ episode ])

      expect(summary(result)).to eq([ [ "Notion", "notion.com", "llm" ], [ "Mercury", nil, "pattern" ] ])
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
      episodes = Array.new(12) { |i| create(:episode, podcast: podcast, description: "Episode #{i}. Sponsored by Hollow Tools.") }
      RubyLLM::Test.stub_responses({ mentions: [] }, { mentions: [] })

      result = described_class.call(podcast, episodes)

      expect(RubyLLM::Test.requests.size).to eq(2)
      expect(result.checked_episode_ids).to match_array(episodes.map(&:id))
      expect(result.detections.size).to eq(12) # the model rejected none
    end

    it "keeps pattern reads but leaves the episodes unscanned when the catalog budget is spent" do
      AppSettings.set(:llm_catalog_daily_usd, 0)
      podcast, episode = podcast_from_fixture("host_reads")
      plain = create(:episode, podcast: podcast, description: "No ads today.")

      result = described_class.call(podcast, [ episode, plain ])

      expect(RubyLLM::Test.requests).to be_empty
      expect(result).to have_attributes(stage2: :budget, checked_episode_ids: [], scanned_episode_ids: [ plain.id ])
      expect(result.detections.map(&:name)).to eq([ "AG1", "Shopify", "Helix Sleep" ])
    end

    it "keeps pattern reads and leaves the episodes unscanned when the provider fails" do
      podcast, episode = podcast_from_fixture("host_reads")
      allow(Sponsors::LlmCheck).to receive(:call).and_raise(Faraday::TimeoutError)
      allow(Rails.error).to receive(:report)

      result = described_class.call(podcast, [ episode ])

      expect(result).to have_attributes(stage2: :failed, scanned_episode_ids: [])
      expect(result.detections.map(&:detected_by).uniq).to eq([ "pattern" ])
      expect(Rails.error).to have_received(:report).with(an_instance_of(Faraday::TimeoutError), hash_including(handled: true))
    end
  end
end
