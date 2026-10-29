require "rails_helper"

RSpec.describe Catalog::RefreshDueJob do
  include ActiveJob::TestHelper

  before { freeze_time }

  it "leases the due podcasts, oldest due first, and queues their ingest at normal priority" do
    due = create(:podcast, next_fetch_at: 1.hour.ago, feed_url: "https://a.example.com/1.xml")
    older = create(:podcast, next_fetch_at: 2.hours.ago, feed_url: "https://b.example.com/1.xml")
    create(:podcast, next_fetch_at: 1.hour.from_now)
    create(:podcast, next_fetch_at: nil)
    create(:podcast, next_fetch_at: 1.hour.ago, status: "removed")
    create(:podcast, next_fetch_at: 1.hour.ago, leased_until: 5.minutes.from_now)

    described_class.perform_now

    expect(Catalog::IngestPodcastJob).to have_been_enqueued.with(due.id).at_priority(10)
    expect(Catalog::IngestPodcastJob).to have_been_enqueued.with(older.id).at_priority(10)
    expect(enqueued_jobs.size).to eq(2)
    expect([ due.reload.leased_until, older.reload.leased_until ]).to all(eq(described_class::LEASE.from_now))
  end

  it "doesn't queue a leased podcast again on the next run" do
    podcast = create(:podcast, next_fetch_at: 1.hour.ago)
    described_class.perform_now
    described_class.perform_now

    expect(Catalog::IngestPodcastJob).to have_been_enqueued.with(podcast.id).exactly(:once)
  end

  it "takes a batch at a time" do
    stub_const("#{described_class}::BATCH", 2)
    3.times { |i| create(:podcast, next_fetch_at: (i + 1).hours.ago) }
    described_class.perform_now
    expect(enqueued_jobs.size).to eq(2)
  end

  it "spaces the feeds of one host apart, and holds back past the per host limit until the next run" do
    stub_const("#{described_class}::MAX_PER_HOST", 2)
    same_host = Array.new(3) { |i| create(:podcast, next_fetch_at: (10 - i).minutes.ago, feed_url: "https://feeds.host.example/#{i}.xml") }
    elsewhere = create(:podcast, next_fetch_at: 1.minute.ago, feed_url: "https://other.example/feed.xml")

    described_class.perform_now

    waits = enqueued_jobs.to_h { |job| [ job["arguments"].first, job["scheduled_at"] && Time.zone.parse(job["scheduled_at"].to_s) ] }
    expect(waits.keys).to contain_exactly(same_host[0].id, same_host[1].id, elsewhere.id)
    expect(waits[same_host[1].id] - waits[same_host[0].id]).to eq(described_class::HOST_SPACING.to_f)
    expect(same_host[2].reload.leased_until).to be_nil
    expect(same_host[1].reload.leased_until).to be_present
  end
end
