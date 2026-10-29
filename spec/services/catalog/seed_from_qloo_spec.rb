require "rails_helper"

# Qloo is the Fake taste provider (config/fake_taste_catalog.yml, made-up shows) and the directory the demo one, whose
# shows have the same titles. Nothing here is real Qloo data.
RSpec.describe Catalog::SeedFromQloo do
  include ActiveJob::TestHelper

  let(:sleeps) { [] }
  let(:sleeper) { ->(seconds) { sleeps << seconds } }
  let(:clock) { -> { 100.0 } }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    Podcasts::Directory.reset!
    allow(Rails).to receive(:cache).and_return(cache)
  end

  def seed(**options) = described_class.call(sleeper: sleeper, clock: clock, **options)

  it "pages Qloo's podcasts by genre tag under the popularity cap, and links each to its feed" do
    allow(Taste::Provider.current).to receive(:recommend).and_call_original
    result = seed(target: 1000)

    expect(result.stopped).to eq("exhausted")
    expect(Podcast.where.not(qloo_entity_id: nil).count).to eq(16)
    expect(result.linked).to eq(16)
    expect([ result.matched, result.added ]).to eq([ 16, 16 ])
    expect(Podcast.pluck(:source).uniq).to eq([ "qloo_seed" ])
    expect(Podcast.where(qloo_popularity: nil)).to be_empty
    expect(Taste::Provider.current).to have_received(:recommend)
      .with(type: :podcast, filter_tags: [ "urn:tag:genre:media:business" ], popularity_max: 0.9, take: 50, offset: nil)
    expect(Catalog::IngestPodcastJob).to have_been_enqueued.exactly(16).times
    expect(enqueued_jobs.map { |job| job["priority"] }.uniq).to eq([ 20 ])
  end

  it "paces directory searches to one a second" do
    seed(target: 1000)
    expect(sleeps.size).to eq(15)
    expect(sleeps).to all(eq(1.0))
  end

  it "stops at the target" do
    result = seed(target: 3)
    expect(result.stopped).to eq("target")
    expect(Podcast.where.not(qloo_entity_id: nil).count).to eq(3)
  end

  it "skips what an earlier run matched or missed, so a re-run costs no directory calls" do
    seed(target: 4)
    directory = Podcasts::Directory.current
    allow(directory).to receive(:search).and_call_original
    create(:podcast, title: "Unmatched Show")

    result = seed(target: 4)
    expect(result.stopped).to eq("target")
    expect(directory).not_to have_received(:search)

    allow(Catalog::QlooMatch).to receive(:call).and_return(nil)
    seed(target: 1000)
    allow(Catalog::QlooMatch).to receive(:call).and_call_original
    missed = seed(target: 1000)
    expect(missed.missed).to eq(0)
  end

  it "drops a tag Qloo won't take and carries on" do
    allow(Taste::Provider.current).to receive(:recommend).and_call_original
    allow(Taste::Provider.current).to receive(:recommend).with(hash_including(filter_tags: [ "urn:tag:genre:media:bogus" ]))
                                                           .and_raise(Taste::BadRequest)
    result = seed(target: 1000, tags: [ "urn:tag:genre:media:bogus", "urn:tag:genre:media:comedy" ])
    expect([ result.stopped, result.linked ]).to eq([ "exhausted", 1 ])
  end

  it "stops when Qloo's call caps are reached, keeping what it linked" do
    allow(Taste::Provider.current).to receive(:recommend).and_raise(Taste::CallCapReached, "the daily limit")
    expect(seed(target: 1000).stopped).to eq("qloo_limit")
  end
end
