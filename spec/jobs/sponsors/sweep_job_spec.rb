require "rails_helper"

# The daily sponsors sweep (config/recurring.yml): active podcasts with episodes due, a modest batch a day.
RSpec.describe Sponsors::SweepJob do
  include ActiveJob::TestHelper

  def active_episode(**attributes) = create(:episode, podcast: create(:podcast, :active), **attributes)

  it "queues a scan for up to the limit of active podcasts with episodes due, oldest first, never an inactive one" do
    allow(Llm).to receive(:mode).and_return(:fake)
    first = active_episode.podcast
    second = active_episode.podcast
    active_episode(sponsor_scanned_at: 1.day.ago)
    active_episode(published_at: 60.days.ago)
    create(:episode, podcast: create(:podcast, status: "removed"))
    create(:episode, podcast: create(:podcast, status: "dormant"))
    create(:episode)

    expect(described_class.perform_now(1)).to eq(1)
    expect(Sponsors::ScanJob).to have_been_enqueued.with(first.id, anything, rescan: false).exactly(:once)
    expect(Sponsors::ScanJob).not_to have_been_enqueued.with(second.id, anything, anything)

    clear_enqueued_jobs
    expect(described_class.perform_now).to eq(2)
  end

  context "with the model" do
    before do
      allow(Llm).to receive(:mode).and_return(:live)
      @old_key = RubyLLM.config.openrouter_api_key
      RubyLLM.config.openrouter_api_key = "test-key"
    end

    after { RubyLLM.config.openrouter_api_key = @old_key }

    it "queues episodes the model never checked, an older pattern scan's too, and never a checked one" do
      checked = active_episode(sponsor_scanned_at: 1.day.ago, sponsor_ai_checked_at: 1.day.ago)
      patterned = active_episode(sponsor_scanned_at: 1.day.ago)

      expect(described_class.perform_now).to eq(1)
      expect(Sponsors::ScanJob).to have_been_enqueued.with(patterned.podcast.id, [ patterned.id ], rescan: false)
      expect(Sponsors::ScanJob).not_to have_been_enqueued.with(checked.podcast.id, anything, anything)
    end

    it "queues nothing while the catalog budget can't pay for a call" do
      AppSettings.set(:llm_catalog_daily_usd, 0)
      active_episode

      expect(described_class.perform_now).to eq(0)
      expect(Sponsors::ScanJob).not_to have_been_enqueued
    end
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
