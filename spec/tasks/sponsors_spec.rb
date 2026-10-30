require "rails_helper"
require "rake"

RSpec.describe "rake sponsors" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("sponsors:scan") }

  before do
    %w[sponsors:scan sponsors:scan_unscanned sponsors:estimate sponsors:rescan sponsors:recount].each { |name| Rake::Task[name].reenable }
    allow(Llm).to receive(:mode).and_return(:fake)
  end

  def active_episode(**attributes) = create(:episode, podcast: create(:podcast, :active), **attributes)

  it "queues a scan for active podcasts with episodes due" do
    waiting = active_episode.podcast
    done = active_episode(sponsor_scanned_at: 1.day.ago).podcast
    removed = create(:episode, podcast: create(:podcast, status: "removed")).podcast

    expect { Rake::Task["sponsors:scan"].invoke }.to output(/Queued sponsor scans for 1 podcast\n/).to_stdout
      .and have_enqueued_job(Sponsors::ScanJob).with(waiting.id, anything, rescan: false).exactly(:once)
    expect(Sponsors::ScanJob).not_to have_been_enqueued.with(done.id, anything, anything)
    expect(Sponsors::ScanJob).not_to have_been_enqueued.with(removed.id, anything, anything)
  end

  describe "sponsors:scan_unscanned" do
    it "queues every active podcast with episodes the model never checked, the newest first, and never a checked one" do
      allow(Llm).to receive(:mode).and_return(:live)
      older = active_episode.podcast
      newer = active_episode.podcast
      checked = active_episode(sponsor_scanned_at: 1.day.ago, sponsor_ai_checked_at: 1.day.ago)
      outside = active_episode(published_at: 60.days.ago)
      dormant = create(:episode, podcast: create(:podcast, status: "dormant")).podcast
      failed = create(:episode, podcast: create(:podcast, status: "failed")).podcast
      patterned = active_episode(sponsor_scanned_at: 1.day.ago)

      already = ActiveJob::Base.queue_adapter.enqueued_jobs.size
      expect { Rake::Task["sponsors:scan_unscanned"].invoke }
        .to output(/Queued sponsor scans for 3 podcasts \(episodes from the last 30 days, at most 10 per podcast a run\)\n/).to_stdout

      queued = ActiveJob::Base.queue_adapter.enqueued_jobs.drop(already).select { |job| job["job_class"] == "Sponsors::ScanJob" }
      expect(queued.map { |job| job["arguments"].first }).to eq([ patterned.podcast_id, newer.id, older.id ])
      expect(queued.first["arguments"].second).to eq([ patterned.id ])
      expect(queued.map { |job| job["arguments"].first }).not_to include(checked.podcast_id, outside.podcast_id, dormant.id, failed.id)
      expect(checked.reload.sponsor_ai_checked_at).to be_present
    end

    it "says why nothing was queued while the catalog budget can't pay for a call" do
      allow(Llm).to receive(:mode).and_return(:live)
      AppSettings.set(:llm_catalog_daily_usd, 0)
      active_episode

      expect { expect { Rake::Task["sponsors:scan_unscanned"].invoke }.not_to have_enqueued_job(Sponsors::ScanJob) }
        .to output(/Queued sponsor scans for 0 podcasts .*budget can't pay for a call/).to_stdout
    end
  end

  describe "sponsors:estimate" do
    before { allow(Llm).to receive(:mode).and_return(:live) }

    it "prices the episodes due without calling the model" do
      podcast = create(:podcast, :active, cadence_days: 7)
      create(:podcast, :active, cadence_days: nil)
      notes = "a" * 3000
      12.times { |i| create(:episode, podcast: podcast, description: notes, published_at: (i + 1).days.ago) }
      create(:episode, podcast: podcast, description: notes, published_at: 40.days.ago)
      create(:episode, podcast: podcast, description: "Short.", published_at: 1.day.ago)
      create(:episode, podcast: podcast, description: notes, published_at: 1.day.ago, sponsor_ai_checked_at: 1.day.ago)

      estimate = Sponsors::Estimate.call
      call_tokens = ((Sponsors::LlmCheck::INSTRUCTIONS.length + Sponsors::LlmCheck::SCHEMA.to_json.length) / 4) + 100
      input = (2 * call_tokens) + (12 * 20) + (12 * 2000 / 4)
      expect(estimate).to have_attributes(days: 30, model: "z-ai/glm-5.3-flash", podcasts: 1, episodes: 12, calls: 2,
                                          input_tokens: input, output_tokens: 12 * 40)
      expect(estimate.cost_usd).to eq(((input * BigDecimal("0.30")) + (480 * BigDecimal("1.20"))) / 1_000_000)
      expect(estimate.new_per_day).to be_within(0.001).of(2.0 / 7)

      expect(Sponsors::Estimate.call(days: 60, model: "z-ai/glm-5.3")).to have_attributes(episodes: 13, calls: 2)
      expect(RubyLLM::Test.requests).to be_empty
    end

    it "prints the count and the cost for the window and model asked for" do
      create(:episode, podcast: create(:podcast, :active), description: "a" * 500, published_at: 50.days.ago)

      expect { Rake::Task["sponsors:estimate"].invoke("60", "z-ai/glm-5.3") }
        .to output(%r{z-ai/glm-5\.3, episodes from the last 60 days.*\nEligible: 1 episode on 1 podcast, 1 call\n.*Cost: about \$0\.00}m).to_stdout
    end
  end

  # Code review L9: deleting a podcast or an episode removes its mentions with delete_all, past the counter cache.
  it "recounts brands whose sponsor read count drifted" do
    brand = create(:brand, name: "Mercury")
    kept = create(:sponsor_mention, brand: brand)
    create(:sponsor_mention, brand: brand).episode.podcast.destroy!
    untouched = create(:brand, name: "Ramp")
    create(:sponsor_mention, brand: untouched)
    expect(brand.reload.sponsor_mentions_count).to eq(2)

    expect { Rake::Task["sponsors:recount"].invoke }.to output(/1 brand corrected/).to_stdout
    expect(brand.reload.sponsor_mentions_count).to eq(1)
    expect(untouched.reload.sponsor_mentions_count).to eq(1)
    expect(kept.reload).to be_present
    expect(Sponsors::Recount.call).to eq(0)
  end

  it "rescans every episode of one podcast on an admin's request" do
    episode = create(:episode, sponsor_scanned_at: 1.day.ago, sponsor_ai_checked_at: 1.day.ago)

    expect { Rake::Task["sponsors:rescan"].invoke(episode.podcast.slug) }.to output(/Queued a rescan of 1 episode/).to_stdout
      .and have_enqueued_job(Sponsors::ScanJob).with(episode.podcast.id, [ episode.id ], rescan: true)
  end
end
