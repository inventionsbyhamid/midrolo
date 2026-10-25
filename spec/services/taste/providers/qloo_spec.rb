require "rails_helper"

RSpec.describe Taste::Providers::Qloo do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:guard) { Taste::CallGuard.new(store: ActiveSupport::Cache::MemoryStore.new) }
  let(:sleeps) { [] }
  let(:adapter) do
    described_class.new(api_key: "test-key", cache: cache, guard: guard, retry_interval: 0.25, sleeper: ->(seconds) { sleeps << seconds })
  end
  let(:base) { "https://hackathon.api.qloo.com" }

  def fixture(name) = Rails.root.join("spec/fixtures/qloo/#{name}.json").read

  def json(name, status: 200, headers: {})
    { status: status, body: fixture(name), headers: { "Content-Type" => "application/json" }.merge(headers) }
  end

  describe "#recommend" do
    let(:params) do
      { type: :brand, entity_ids: [ "E1" ], tag_ids: [ "T1" ], filter_tags: [ "urn:tag:genre:brand:finance" ], popularity_max: 0.9, take: 50 }
    end

    it "sends the insights request shape and maps entities, reading affinity and website tolerantly" do
      stub = stub_request(:get, "#{base}/v2/insights").with(
        query: {
          "filter.type" => "urn:entity:brand", "signal.interests.entities" => "E1", "signal.interests.tags" => "T1",
          "filter.tags" => "urn:tag:genre:brand:finance", "filter.popularity.max" => "0.9", "take" => "50"
        },
        headers: { "X-Api-Key" => "test-key" }
      ).to_return(json("insights_brand"))

      entities = adapter.recommend(**params)

      expect(stub).to have_been_requested
      expect(entities.map(&:id)).to eq(%w[SYN-BRAND-001 SYN-BRAND-002 SYN-BRAND-003])
      a, b, c = entities
      expect(a).to be_a(Taste::Entity)
      expect(a.type).to eq(:brand)
      expect(a.affinity).to eq(0.87)
      expect(b.affinity).to eq(0.64)
      expect(a.website).to eq("https://acmeledger.example.com")
      expect(b.website).to eq("https://borealis.example.com")
      expect(c.website).to eq("https://cobalt.example.com")
      expect(a.image_url).to eq("https://img.example.com/acme.png")
      expect(a.description).to eq("Synthetic bookkeeping software.")
      expect(a.popularity).to eq(0.42)
      expect(a.tags.first).to eq(Taste::Tag.new(id: "urn:tag:genre:brand:finance", name: "Finance", type: "urn:tag:genre:brand", score: nil))
      expect(b.tags.first.id).to eq("urn:tag:genre:brand:finance")
    end

    it "joins array params with commas" do
      stub = stub_request(:get, "#{base}/v2/insights")
        .with(query: hash_including("signal.interests.entities" => "E1,E2")).to_return(json("empty"))
      expect(adapter.recommend(type: :artist, entity_ids: %w[E1 E2])).to eq([])
      expect(stub).to have_been_requested
    end

    it "returns [] for an empty entities array" do
      stub_request(:get, "#{base}/v2/insights").with(query: hash_including({})).to_return(json("empty"))
      expect(adapter.recommend(type: :brand, entity_ids: [ "E1" ])).to eq([])
    end

    it "rejects unknown types" do
      expect { adapter.recommend(type: :spaceship) }.to raise_error(ArgumentError)
    end

    it "reads image, description, website and tags flat or under properties (M6)" do
      stub_request(:get, "#{base}/v2/insights").with(query: hash_including({})).to_return(json("insights_brand_flat"))

      flat, nested, mixed = adapter.recommend(type: :brand, entity_ids: [ "E1" ])

      expect(flat).to have_attributes(image_url: "https://images.example.com/i/delta-420x-auto.jpg",
                                      description: "Synthetic flat description.", website: "https://deltadough.example.com",
                                      affinity: 0.71)
      expect(flat.tags.map(&:id)).to eq([ "urn:tag:genre:brand:food_and_beverage" ])
      expect(nested).to have_attributes(image_url: "https://img.example.com/echo.png", website: "https://echo.example.com",
                                        description: nil)
      expect(nested.tags.map(&:id)).to eq([ "urn:tag:genre:brand:fashion" ])
      expect(mixed).to have_attributes(image_url: "https://img.example.com/foxglove.png", website: "https://foxglove.example.com")
    end
  end

  describe "#search" do
    it "maps podcasts using the urn type" do
      stub_request(:get, "#{base}/search").with(query: { "query" => "widget", "types" => "urn:entity:podcast", "take" => "5" })
        .to_return(json("search"))
      results = adapter.search(query: "widget", types: [ :podcast ])
      expect(results.map(&:name)).to eq([ "Widget Hour", "Gadget Gossip" ])
      expect(results.first.type).to eq(:podcast)
      expect(results.first.website).to eq("https://widgethour.example.com")
      expect(results.last.affinity).to be_nil
    end

    it "returns [] when Qloo answers 404 No results (M1), and doesn't cache the miss" do
      stub = stub_request(:get, "#{base}/search").with(query: hash_including({}))
        .to_return(status: 404, body: '{"code":404,"reason":"Not Found","message":"No results"}')
      2.times { expect(adapter.search(query: "zzqxv nonexistent show", types: [ :podcast ])).to eq([]) }
      expect(stub).to have_been_requested.twice
    end
  end

  describe "#find_tags and #taste_tags" do
    it "maps tags with id/tag_id and type/subtype variants" do
      stub_request(:get, "#{base}/v2/tags").with(query: { "filter.query" => "business", "feature.semantic_search" => "true", "take" => "10" })
        .to_return(json("tags"))
      tags = adapter.find_tags(query: "business")
      expect(tags.map(&:id)).to eq(%w[urn:tag:genre:media:business urn:tag:genre:media:entrepreneurship])
      expect(tags.last.type).to eq("urn:tag:genre:media")
    end

    it "scopes a tag lookup to tag types with filter.tag.types (M4)" do
      stub = stub_request(:get, "#{base}/v2/tags").with(query: {
        "filter.query" => "food and beverage", "feature.semantic_search" => "true", "take" => "10",
        "filter.tag.types" => "urn:tag:genre:brand"
      }).to_return(json("tags"))
      adapter.find_tags(query: "food and beverage", types: [ "urn:tag:genre:brand" ])
      expect(stub).to have_been_requested
    end

    it "requests the tag taste profile" do
      stub = stub_request(:get, "#{base}/v2/insights")
        .with(query: { "filter.type" => "urn:tag", "signal.interests.entities" => "E1", "take" => "20" }).to_return(json("insights_tags"))
      tags = adapter.taste_tags(entity_ids: [ "E1" ])
      expect(stub).to have_been_requested
      expect(tags.map(&:score)).to eq([ 0.91, 0.4 ])
    end
  end

  describe "#affinity_for" do
    it "scopes insights to candidate ids and returns id => affinity" do
      stub = stub_request(:get, "#{base}/v2/insights")
        .with(query: hash_including("filter.results.entities" => "SYN-BRAND-001,SYN-BRAND-002", "signal.interests.entities" => "E1"))
        .to_return(json("insights_brand"))
      result = adapter.affinity_for(candidate_ids: %w[SYN-BRAND-001 SYN-BRAND-002], entity_ids: [ "E1" ])
      expect(stub).to have_been_requested
      expect(result).to eq("SYN-BRAND-001" => 0.87, "SYN-BRAND-002" => 0.64)
    end

    it "maps candidates Qloo did not return to nil" do
      stub_request(:get, "#{base}/v2/insights").with(query: hash_including({})).to_return(json("insights_brand"))
      result = adapter.affinity_for(candidate_ids: %w[SYN-BRAND-001 MISSING])
      expect(result).to eq("SYN-BRAND-001" => 0.87, "MISSING" => nil)
    end

    it "chunks 120 candidates into 3 requests and returns a key for each" do
      stub = stub_request(:get, "#{base}/v2/insights").with(query: hash_including("filter.type" => "urn:entity:artist"))
        .to_return(json("empty"))
      ids = (1..120).map { |i| "C#{i}" }
      result = adapter.affinity_for(candidate_ids: ids, entity_ids: [ "E1" ], type: :artist)
      expect(stub).to have_been_requested.times(3)
      expect(result.keys).to eq(ids)
      expect(result.values.uniq).to eq([ nil ])
    end
  end

  describe "tag signals" do
    def tag_query(tag_ids)
      stub_request(:get, "#{base}/v2/insights").with(query: hash_including("signal.interests.tags" => tag_ids.join(","))).to_return(json("empty"))
      adapter.recommend(type: :brand, tag_ids: tag_ids)
      WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last.uri.query_values
    end

    it "sends operator union only when more than one tag is given" do
      expect(tag_query(%w[T1 T2])["operator.signal.interests.tags"]).to eq("union")
      expect(tag_query(%w[T9])).not_to have_key("operator.signal.interests.tags")
    end

    it "applies to the other signal-based calls too" do
      stub = stub_request(:get, "#{base}/v2/insights")
        .with(query: hash_including("signal.interests.tags" => "T1,T2", "operator.signal.interests.tags" => "union")).to_return(json("empty"))
      adapter.taste_tags(tag_ids: %w[T1 T2])
      adapter.demographics(tag_ids: %w[T1 T2])
      adapter.heatmap(location: "US", tag_ids: %w[T1 T2])
      adapter.affinity_for(candidate_ids: [ "x" ], tag_ids: %w[T1 T2])
      expect(stub).to have_been_requested.times(4)
    end
  end

  describe "#demographics" do
    it "parses results.demographics[0].query into hashes" do
      stub_request(:get, "#{base}/v2/insights").with(query: { "filter.type" => "urn:demographics", "signal.interests.entities" => "SYN-POD-001" })
        .to_return(json("demographics"))
      demo = adapter.demographics(entity_ids: [ "SYN-POD-001" ])
      expect(demo).to be_a(Taste::Demographics)
      expect(demo.age["30_to_34"]).to eq(0.31)
      expect(demo.age.keys.size).to eq(6)
      expect(demo.gender).to eq("male" => 0.18, "female" => -0.18)
    end

    it "returns empty hashes when there is no demographics data" do
      stub_request(:get, "#{base}/v2/insights").with(query: hash_including({})).to_return(body: '{"results":{"demographics":[]}}')
      expect(adapter.demographics(entity_ids: [ "x" ])).to eq(Taste::Demographics.new(age: {}, gender: {}))
    end

    it "averages every per-signal block, each bucket over the blocks that have it (M3)" do
      stub_request(:get, "#{base}/v2/insights")
        .with(query: hash_including("filter.type" => "urn:demographics", "signal.interests.entities" => "SYN-POD-001",
                                    "signal.interests.tags" => "urn:tag:genre:media:business"))
        .to_return(json("demographics_two_blocks"))

      demo = adapter.demographics(entity_ids: [ "SYN-POD-001" ], tag_ids: [ "urn:tag:genre:media:business" ])

      expect(demo.age).to eq("24_and_younger" => -0.1, "25_to_29" => 0.2, "30_to_34" => 0.2, "35_to_44" => 0.0,
                             "45_to_54" => -0.1, "55_and_older" => -0.3)
      expect(demo.gender).to eq("male" => -0.1, "female" => 0.1)
    end
  end

  describe "#heatmap" do
    it "sends the heatmap request and maps points" do
      stub = stub_request(:get, "#{base}/v2/insights").with(query: {
        "filter.type" => "urn:heatmap", "filter.location.query" => "United States", "output.heatmap.boundary" => "urn:entity:locality",
        "signal.interests.entities" => "E1", "take" => "50"
      }).to_return(json("heatmap"))
      points = adapter.heatmap(location: "United States", entity_ids: [ "E1" ])
      expect(stub).to have_been_requested
      expect(points.size).to eq(2)
      expect(points.first).to eq(Taste::HeatPoint.new(lat: 40.71, lng: -74.0, geohash: "dr5regw", affinity: 0.9, popularity: 0.4, label: "New York"))
      expect(points.last.label).to be_nil
    end

    it "reads lat with lon or lng, nested under location or flat, and drops points off the globe (M5)" do
      stub_request(:get, "#{base}/v2/insights").with(query: hash_including("filter.type" => "urn:heatmap")).to_return(json("heatmap_locality"))
      points = adapter.heatmap(location: "United States", entity_ids: [ "E1" ])

      expect(points).to eq([
        Taste::HeatPoint.new(lat: 41.88, lng: -87.63, geohash: nil, affinity: 0.8, popularity: 0.5, label: "Chicago"),
        Taste::HeatPoint.new(lat: 47.61, lng: -122.33, geohash: nil, affinity: 0.7, popularity: nil, label: nil),
        Taste::HeatPoint.new(lat: 30.27, lng: -97.74, geohash: nil, affinity: 0.6, popularity: 0.2, label: "Austin")
      ])
    end

    it "warns, naming the keys it saw, when a non-empty heatmap parses to no points (M5)" do
      stub_request(:get, "#{base}/v2/insights").with(query: hash_including("filter.type" => "urn:heatmap")).to_return(json("heatmap_unknown"))
      allow(Rails.logger).to receive(:warn)

      expect(adapter.heatmap(location: "United States", entity_ids: [ "E1" ])).to eq([])
      expect(Rails.logger).to have_received(:warn).with(a_string_including("2 heatmap entries", "geo", "score"))
    end

    it "returns no points when Qloo can't place the location, a 400 (M2), and doesn't cache the miss" do
      stub = stub_request(:get, "#{base}/v2/insights").with(query: hash_including("filter.location.query" => "Atlantis"))
        .to_return(status: 400, body: '{"message":"No localities found"}')
      2.times { expect(adapter.heatmap(location: "Atlantis", entity_ids: [ "E1" ])).to eq([]) }
      expect(stub).to have_been_requested.twice
    end
  end

  describe "#compare" do
    it "calls the compare endpoint and maps results.tags" do
      stub = stub_request(:get, "#{base}/v2/analysis/compare")
        .with(query: { "a.signal.interests.entities" => "A1", "b.signal.interests.entities" => "B1,B2", "take" => "10" })
        .to_return(json("compare"))
      tags = adapter.compare(a_entity_ids: [ "A1" ], b_entity_ids: %w[B1 B2])
      expect(stub).to have_been_requested
      expect(tags.map(&:name)).to eq(%w[Business Finance])
      expect(tags.first.score).to eq(0.77)
    end

    it "returns [] for a podcast against a brand: no shared tags, only each side's own (R105)" do
      body = { results: { tags: [],
                          a: { tags: [ { tag_id: "urn:tag:genre:media:comedy", name: "Comedy", query: { count: 3 } } ] },
                          b: { tags: [ { tag_id: "urn:tag:genre:brand:finance", name: "Finance", query: { count: 2 } } ] } } }
      stub_request(:get, "#{base}/v2/analysis/compare").with(query: hash_including({})).to_return(status: 200, body: body.to_json)
      expect(adapter.compare(a_entity_ids: [ "SYN-POD-001" ], b_entity_ids: [ "SYN-BRAND-001" ])).to eq([])
    end

    it "returns [] when Qloo answers 404 No results (M1)" do
      stub_request(:get, "#{base}/v2/analysis/compare").with(query: hash_including({}))
        .to_return(status: 404, body: '{"code":404,"reason":"Not Found","message":"No results"}')
      expect(adapter.compare(a_entity_ids: [ "A1" ], b_entity_ids: [ "B1" ])).to eq([])
    end
  end

  describe "errors" do
    it "raises AuthError on 401 only, and does not cache it (M7)" do
      stub = stub_request(:get, "#{base}/v2/tags").with(query: hash_including({})).to_return(status: 401, body: '{"message":"bad key"}')
      2.times { expect { adapter.find_tags(query: "x") }.to raise_error(Taste::AuthError) }
      expect(stub).to have_been_requested.twice
    end

    it "raises Unsupported, never AuthError, on a 403 for an entity type the key can't use (M7)" do
      stub_request(:get, "#{base}/v2/insights").with(query: hash_including({}))
        .to_return(status: 403, body: '{"message":"You do not have permission to access urn:demographics"}')
      expect { adapter.demographics(entity_ids: [ "E1" ]) }.to raise_error(Taste::Unsupported) do |error|
        expect(error).to be_a(Taste::Error)
        expect(error).not_to be_a(Taste::AuthError)
      end
    end

    it "raises NotFound on a 404 from a call where it doesn't mean no results" do
      stub_request(:get, "#{base}/v2/tags").with(query: hash_including({})).to_return(status: 404, body: "{}")
      expect { adapter.find_tags(query: "x") }.to raise_error(Taste::NotFound)
    end

    it "raises BadRequest on other 400s, logging the param names but never the key (M2)" do
      stub_request(:get, "#{base}/v2/tags").with(query: hash_including({}))
        .to_return(status: 400, body: '{"message":"at least one valid signal or filter is required"}')
      allow(Rails.logger).to receive(:warn)

      expect { adapter.find_tags(query: "secret show title") }.to raise_error(Taste::BadRequest)
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("HTTP 400", "filter.query", "feature.semantic_search", "take")
                .and(satisfy { |line| !line.include?("test-key") && !line.include?("secret show title") }))
    end

    it "raises Unavailable on timeouts and bad JSON" do
      stub_request(:get, "#{base}/v2/tags").with(query: hash_including("filter.query" => "t")).to_timeout
      expect { adapter.find_tags(query: "t") }.to raise_error(Taste::Unavailable)
      stub_request(:get, "#{base}/v2/tags").with(query: hash_including("filter.query" => "j")).to_return(status: 200, body: "<html>")
      expect { adapter.find_tags(query: "j") }.to raise_error(Taste::Unavailable)
    end
  end

  describe "retries (R92)" do
    def tags_stub = stub_request(:get, "#{base}/v2/tags").with(query: hash_including({}))

    it "waits out a 429's Retry-After of 5 seconds or less once, then retries once" do
      stub = tags_stub.to_return({ status: 429, headers: { "Retry-After" => "5" } }, json("tags"))
      expect(adapter.find_tags(query: "x").size).to eq(2)
      expect(stub).to have_been_requested.twice
      expect(sleeps).to eq([ 5 ])
    end

    it "raises RateLimited when the one retry gets a 429 too" do
      stub = tags_stub.to_return(status: 429, headers: { "Retry-After" => "1" }, body: '{"code":429,"reason":"rate","message":"slow"}')
      expect { adapter.find_tags(query: "x") }.to raise_error(Taste::RateLimited)
      expect(stub).to have_been_requested.twice
      expect(sleeps).to eq([ 1 ])
    end

    it "never retries a 429 blindly: a long, missing or unreadable Retry-After raises at once" do
      [ { "Retry-After" => "30" }, {}, { "Retry-After" => "soon" } ].each_with_index do |headers, i|
        stub = stub_request(:get, "#{base}/v2/tags").with(query: hash_including("filter.query" => "q#{i}")).to_return(status: 429, headers: headers)
        expect { adapter.find_tags(query: "q#{i}") }.to raise_error(Taste::RateLimited)
        expect(stub).to have_been_requested.once
      end
      expect(sleeps).to be_empty
    end

    it "reads a Retry-After given as an HTTP date" do
      travel_to Time.utc(2026, 10, 25, 12) do
        tags_stub.to_return({ status: 429, headers: { "Retry-After" => (Time.current + 3).httpdate } }, json("tags"))
        expect(adapter.find_tags(query: "x").size).to eq(2)
        expect(sleeps).to eq([ 3 ])
      end
    end

    it "retries a 5xx once after a short backoff, then raises Unavailable" do
      stub = tags_stub.to_return(status: 503)
      expect { adapter.find_tags(query: "x") }.to raise_error(Taste::Unavailable)
      expect(stub).to have_been_requested.twice
      expect(sleeps).to eq([ 0.25 ])
    end

    it "recovers when the retry after a 5xx succeeds" do
      tags_stub.to_return({ status: 502 }, json("tags"))
      expect(adapter.find_tags(query: "x").size).to eq(2)
    end

    it "retries a timeout once, then raises Unavailable" do
      stub = tags_stub.to_timeout
      expect { adapter.find_tags(query: "x") }.to raise_error(Taste::Unavailable)
      expect(stub).to have_been_requested.twice
      expect(sleeps).to eq([ 0.25 ])
    end

    it "never retries a 4xx" do
      { 400 => Taste::BadRequest, 401 => Taste::AuthError, 403 => Taste::Unsupported, 404 => Taste::NotFound,
        422 => Taste::Error }.each do |status, error|
        stub = stub_request(:get, "#{base}/v2/tags").with(query: hash_including("filter.query" => "s#{status}")).to_return(status: status)
        expect { adapter.find_tags(query: "s#{status}") }.to raise_error(error)
        expect(stub).to have_been_requested.once
      end
      expect(sleeps).to be_empty
    end
  end

  describe "call guard (R92)" do
    it "refuses before any HTTP request once a cap is reached" do
      AppSettings.set(:qloo_daily_call_limit, 1)
      stub = stub_request(:get, "#{base}/v2/tags").with(query: hash_including({})).to_return(json("tags"))

      adapter.find_tags(query: "a")
      expect { adapter.find_tags(query: "b") }.to raise_error(Taste::CallCapReached)
      expect(stub).to have_been_requested.once
    end

    it "serves cached answers without taking a slot" do
      AppSettings.set(:qloo_daily_call_limit, 1)
      stub_request(:get, "#{base}/v2/tags").with(query: hash_including({})).to_return(json("tags"))

      2.times { adapter.find_tags(query: "a") }
      expect(guard.usage.today).to eq(1)
    end

    it "takes a slot for every attempt, a retry included" do
      stub_request(:get, "#{base}/v2/tags").with(query: hash_including({})).to_return({ status: 503 }, json("tags"))
      adapter.find_tags(query: "a")
      expect(guard.usage.today).to eq(2)
    end

    it "stops before the retry when the retry would pass a cap" do
      AppSettings.set(:qloo_daily_call_limit, 1)
      stub = stub_request(:get, "#{base}/v2/tags").with(query: hash_including({})).to_return(status: 503)
      expect { adapter.find_tags(query: "a") }.to raise_error(Taste::CallCapReached)
      expect(stub).to have_been_requested.once
    end
  end

  describe "caching and instrumentation" do
    it "serves a repeated identical call from cache and reports cached: true" do
      stub = stub_request(:get, "#{base}/v2/tags").with(query: hash_including({})).to_return(json("tags"))
      events = []
      sub = ActiveSupport::Notifications.subscribe("request.taste") { |*, payload| events << payload }

      adapter.find_tags(query: "business")
      adapter.find_tags(query: "business")

      expect(stub).to have_been_requested.times(1)
      expect(events.map { |e| e[:cached] }).to eq([ false, true ])
      expect(events.first).to include(path: "/v2/tags", status: 200)
      expect(events.first[:duration_ms]).to be_a(Numeric)
      expect(cache.instance_variable_get(:@data).keys.first).to match(/\Ataste:v1:\h{64}\z/)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    it "keeps lookups by name and tag lookups 30 days, every other answer 7 (R93)" do
      stub_request(:get, "#{base}/search").with(query: hash_including({})).to_return(json("search"))
      stub_request(:get, "#{base}/v2/tags").with(query: hash_including({})).to_return(json("tags"))
      stub_request(:get, "#{base}/v2/insights").with(query: hash_including({})).to_return(json("insights_brand"))
      allow(cache).to receive(:write).and_call_original

      adapter.search(query: "widget", types: [ :podcast ])
      adapter.find_tags(query: "business")
      adapter.recommend(type: :brand, entity_ids: [ "E1" ])

      expect(cache).to have_received(:write).with(anything, anything, expires_in: 30.days).twice
      expect(cache).to have_received(:write).with(anything, anything, expires_in: 7.days).once
    end

    it "keys the cache independent of param order" do
      adapter.send(:cache_key, "/p", { "b" => "1", "a" => "2" }).then do |k|
        expect(k).to eq(adapter.send(:cache_key, "/p", { "a" => "2", "b" => "1" }))
      end
    end

    it "emits an event with the error status when a request fails" do
      stub_request(:get, "#{base}/v2/tags").with(query: hash_including({})).to_return(status: 401)
      events = []
      sub = ActiveSupport::Notifications.subscribe("request.taste") { |*, payload| events << payload }
      expect { adapter.find_tags(query: "x") }.to raise_error(Taste::AuthError)
      expect(events.first).to include(status: 401, cached: false)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
  end
end
