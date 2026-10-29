require "rails_helper"

# The daily sponsors sweep (config/recurring.yml): podcasts with episodes not scanned yet, a modest batch a day.
RSpec.describe Sponsors::SweepJob do
  include ActiveJob::TestHelper

  it "queues a scan for up to the limit of podcasts with unscanned episodes, oldest first, never a removed one" do
    first = create(:episode).podcast
    second = create(:episode).podcast
    create(:episode, sponsor_scanned_at: 1.day.ago)
    create(:episode, podcast: create(:podcast, status: "removed"))

    expect(described_class.perform_now(1)).to eq(1)
    expect(Sponsors::ScanJob).to have_been_enqueued.with(first.id, anything, rescan: false).exactly(:once)
    expect(Sponsors::ScanJob).not_to have_been_enqueued.with(second.id, anything, anything)

    clear_enqueued_jobs
    expect(described_class.perform_now).to eq(2)
  end

  it "recounts brands' sponsor reads that deleting a podcast left wrong (code review L9)" do
    brand = create(:brand)
    create(:sponsor_mention, brand: brand).episode.podcast.destroy!
    expect(brand.reload.sponsor_mentions_count).to eq(1)

    described_class.perform_now
    expect(brand.reload.sponsor_mentions_count).to eq(0)
  end

  it "runs every day in production, on the sponsors queue" do
    recurring = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml"))
    expect(recurring.dig("production", "sweep_sponsors")).to eq("class" => "Sponsors::SweepJob", "schedule" => "every day at 4:10am")
    expect(described_class.new.queue_name).to eq("sponsors")
  end
end
