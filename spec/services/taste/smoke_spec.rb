require "rails_helper"

# The live smoke test, against WebMock only: every endpoint is stubbed with synthetic JSON. Never the real API.
RSpec.describe Taste::Smoke do
  let(:base) { "https://hackathon.api.qloo.com" }
  let(:io) { StringIO.new }
  let(:development) { ActiveSupport::EnvironmentInquirer.new("development") }
  let(:counter) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(counter) }

  def fixture(name) = { status: 200, body: Rails.root.join("spec/fixtures/qloo/#{name}.json").read }

  def smoke(env: development, api_key: "test-key", steps: nil)
    described_class.new(api_key: api_key, env: env, io: io, sleeper: ->(_seconds) { }, steps: steps)
  end

  def insights(params) = stub_request(:get, "#{base}/v2/insights").with(query: hash_including(params))

  # Five synthetic brands, to show that a call prints at most 3 names.
  def five_brands
    entities = (1..5).map do |i|
      { entity_id: "SYN-UNION-#{i}", name: "Union Brand #{i}", subtype: "urn:entity:brand", popularity: 0.5, query: { affinity: 0.5 },
        properties: { description: "Sentinel union description #{i}." } }
    end
    { status: 200, body: { success: true, results: { entities: entities } }.to_json }
  end

  def stub_checklist
    stub_request(:get, "#{base}/search").with(query: hash_including("query" => "SmartLess")).to_return(fixture("search"))
    stub_request(:get, "#{base}/search").with(query: hash_including("query" => "zzqxv nonexistent show"))
      .to_return(status: 404, body: '{"code":404,"reason":"Not Found","message":"No results"}')
    stub_request(:get, "#{base}/v2/tags").with(query: hash_including("filter.tag.types" => "urn:tag:genre:brand")).to_return(fixture("brand_tags"))
    insights("filter.type" => "urn:entity:brand", "signal.interests.entities" => "SYN-POD-001").to_return(fixture("insights_brand"))
    insights("filter.type" => "urn:entity:brand", "operator.signal.interests.tags" => "union").to_return(five_brands)
    insights("filter.type" => "urn:demographics").to_return(fixture("demographics_two_blocks"))
    insights("filter.type" => "urn:heatmap").to_return(fixture("heatmap"))
    insights("filter.type" => "urn:tag").to_return(fixture("insights_tags"))
  end

  describe "refusing to run" do
    it "refuses without QLOO_API_KEY" do
      expect { smoke(api_key: " ").call }.to raise_error(described_class::Refused, /QLOO_API_KEY/)
    end

    it "refuses an unknown step, naming the ones it knows, before any call" do
      expect { smoke(steps: "heatmap,compare").call }.to raise_error(described_class::Refused, /compare.*search_podcast/m)
      expect(a_request(:any, /qloo/)).not_to have_been_made
    end

    it "refuses outside development and production, the test environment included" do
      %w[test staging].each do |name|
        expect { smoke(env: ActiveSupport::EnvironmentInquirer.new(name)).call }.to raise_error(described_class::Refused, /development or production/)
      end
      expect(a_request(:any, /qloo/)).not_to have_been_made
    end
  end

  describe "running the checklist" do
    before { stub_checklist }

    it "makes 8 live calls, within the hard budget of 10, and passes each against its expectation (R105: no compare)" do
      result = smoke.call

      expect(described_class::BUDGET).to eq(10)
      expect(result.calls).to eq(8)
      expect(result.outcomes.keys).not_to include(:compare)
      expect(result.outcomes.values).to all(eq(:pass))
      expect(result).to be_passed
      expect(io.string).to include("8 passed, 0 failed, 0 skipped", "8 live calls of 10")
      expect(a_request(:get, %r{/v2/analysis/compare})).not_to have_been_made
    end

    it "prints the endpoint, status, count, parsing paths and verdict of each call" do
      smoke.call
      out = io.string

      expect(out).to include("GET /search", "HTTP 200", "2 results", "PASS")
      expect(out).to include("HTTP 404", "0 results") # the miss: 404 means no results (M1)
      expect(out).to match(%r{GET /v2/tags .*HTTP 200 .*2 results}) # brand tags (M4)
      expect(out).to include("image at properties.image.url", "description at properties", "website at properties.official_site",
                             "website at official_site (flat)", "affinity at query.affinity", "affinity at affinity (flat)")
      expect(out).to include("2 demographics blocks", "6 age buckets")
      expect(out).to include("points at location.latitude/location.longitude")
    end

    it "prints at most 3 names a call and nothing else from the bodies" do
      smoke.call
      out = io.string

      expect(out).to include("Union Brand 1, Union Brand 2, Union Brand 3")
      expect(out).not_to include("Union Brand 4")
      expect(out).not_to include("Sentinel", "Synthetic", "SYN-", "img.example.com", "example.com")
    end

    it "counts its calls toward the global call guard" do
      smoke.call
      expect(Taste::CallGuard.new.usage.today).to eq(8)
    end

    it "bypasses the response cache: a second run calls Qloo again" do
      smoke.call
      smoke.call
      expect(a_request(:get, "#{base}/search").with(query: hash_including("query" => "SmartLess"))).to have_been_made.twice
    end

    it "writes no file and never prints the key (R110)" do
      writes = []
      %i[write binwrite].each do |name|
        allow(File).to receive(name).and_wrap_original { |original, path, *rest, **opts| writes << path.to_s && original.call(path, *rest, **opts) }
      end
      allow(File).to receive(:open).and_wrap_original do |original, path, *rest, **opts, &block|
        writes << path.to_s if (rest.first || opts[:mode]).to_s.match?(/[wa+]/)
        original.call(path, *rest, **opts, &block)
      end
      key = "synthetic-qloo-key-7f3a"

      smoke(api_key: key).call

      expect(writes).to be_empty
      expect(io.string).not_to include(key)
      expect(a_request(:get, %r{hackathon\.api\.qloo\.com/search}).with(headers: { "X-Api-Key" => key })).to have_been_made.at_least_once
    end

    it "fails a call whose answer breaks its expectation, and says so" do
      insights("filter.type" => "urn:demographics").to_return(fixture("demographics"))
      result = smoke.call

      expect(result.outcomes[:demographics]).to eq(:fail)
      expect(result).not_to be_passed
      expect(io.string).to include("1 demographics block", "FAIL")
    end

    it "passes the miss when Qloo's fuzzy search answers near shows, none close to the nonsense query (R107)" do
      stub_request(:get, "#{base}/search").with(query: hash_including("query" => "zzqxv nonexistent show")).to_return(fixture("search"))
      result = smoke.call

      expect(result.outcomes[:search_miss]).to eq(:pass)
      expect(io.string).to match(/search_miss  GET \/search  HTTP 200  2 results  PASS/)
    end

    it "fails the miss when a result's name is close to the nonsense query" do
      close = { results: [ { entity_id: "SYN-POD-404", name: "Zzqxv Nonexistent Show", subtype: "urn:entity:podcast" } ] }
      stub_request(:get, "#{base}/search").with(query: hash_including("query" => "zzqxv nonexistent show"))
        .to_return(status: 200, body: close.to_json)
      expect(smoke.call.outcomes[:search_miss]).to eq(:fail)
    end

    it "runs only the steps asked for, adding the podcast search they need, so a rerun spends only what it checks (R107)" do
      result = smoke(steps: "heatmap, search_miss").call

      expect(result.outcomes.keys).to eq(%i[search_podcast search_miss heatmap])
      expect(result.calls).to eq(3)
      expect(result).to be_passed
      expect(io.string).to include("3 checks", "3 passed, 0 failed, 0 skipped; 3 live calls of 10")
    end

    it "skips the calls that need a podcast when the search finds none, making no call for them" do
      stub_request(:get, "#{base}/search").with(query: hash_including("query" => "SmartLess")).to_return(status: 200, body: '{"results":[]}')
      result = smoke.call

      expect(result.outcomes.values_at(:brand_recs, :demographics, :heatmap, :taste_tags)).to all(eq(:skip))
      expect(result.calls).to eq(4)
    end
  end

  describe "the budget" do
    it "aborts before an 11th live call, retries included" do
      stub_checklist
      insights("filter.type" => "urn:entity:brand").to_return(status: 503)
      insights("filter.type" => "urn:demographics").to_return(status: 503)
      insights("filter.type" => "urn:heatmap").to_return(status: 503)
      stub_request(:get, "#{base}/v2/tags").with(query: hash_including({})).to_return(status: 503)

      result = smoke.call

      expect(result.calls).to eq(10)
      expect(result).to be_aborted
      expect(result).not_to be_passed
      expect(a_request(:get, /hackathon\.api\.qloo\.com/)).to have_been_made.times(10)
      expect(io.string).to include("ABORT", "budget of 10 live calls")
    end

    it "aborts on a rejected key (401), making no more calls (R110)" do
      stub_request(:get, %r{hackathon\.api\.qloo\.com}).to_return(status: 401, body: '{"message":"No API key found in request"}')

      result = smoke.call

      expect(result).to be_aborted
      expect(result.calls).to eq(1)
      expect(a_request(:get, %r{hackathon\.api\.qloo\.com})).to have_been_made.once
      expect(io.string).to include("ABORT", "rejected the key")
    end

    it "aborts when the global call guard refuses, making no more calls" do
      stub_checklist
      AppSettings.set(:qloo_daily_call_limit, 1)

      result = smoke.call

      expect(result).to be_aborted
      expect(result.calls).to eq(1)
      expect(io.string).to include("ABORT", "call guard")
    end
  end
end
