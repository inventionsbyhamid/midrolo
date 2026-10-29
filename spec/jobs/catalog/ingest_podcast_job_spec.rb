require "rails_helper"

# The job is a thin wrapper around Catalog::Ingest (spec/services/catalog/ingest_spec.rb has the details).
RSpec.describe Catalog::IngestPodcastJob do
  include ActiveJob::TestHelper

  it "runs on the catalog queue at normal priority, one at a time per podcast" do
    expect(described_class.new.queue_name).to eq("catalog")
    expect(described_class.new(1).priority).to eq(10)
    expect(described_class.new(1).concurrency_key).to include("1")
  end

  it "ingests the podcast, passing its own priority on to the artwork it queues" do
    podcast = create(:podcast, feed_url: "fake://fake-1")
    allow(Catalog::Ingest).to receive(:call).and_call_original

    described_class.set(priority: 0).perform_later(podcast.id)
    perform_enqueued_jobs(only: described_class)

    expect(Catalog::Ingest).to have_received(:call).with(podcast, priority: 0)
    podcast.reload
    expect(podcast).to be_active
    expect(podcast.owner_email).to eq("host@the-founder-s-ledger.example")
    stored = Podcast.connection.select_value("SELECT owner_email FROM podcasts WHERE id = #{podcast.id}")
    expect(stored).not_to include("host@")
  end

  it "ignores a deleted or removed podcast" do
    expect { described_class.perform_now(0) }.not_to raise_error

    removed = create(:podcast, feed_url: "fake://fake-1", status: "removed")
    described_class.perform_now(removed.id)
    expect(removed.reload.feed_checked_at).to be_nil
  end

  it "never raises for a bad feed, so the queue moves on" do
    podcast = create(:podcast, feed_url: "fake://nope")
    expect { described_class.perform_now(podcast.id) }.not_to raise_error
    expect(podcast.reload.last_error).to eq("feed_not_found")
  end
end
