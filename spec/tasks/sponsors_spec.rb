require "rails_helper"
require "rake"

RSpec.describe "rake sponsors" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("sponsors:scan") }

  before { %w[sponsors:scan sponsors:rescan sponsors:recount].each { |name| Rake::Task[name].reenable } }

  it "queues a scan for podcasts with unscanned episodes" do
    waiting = create(:episode).podcast
    done = create(:episode, sponsor_scanned_at: 1.day.ago).podcast
    removed = create(:episode, podcast: create(:podcast, status: "removed")).podcast

    expect { Rake::Task["sponsors:scan"].invoke }.to output(/Queued sponsor scans for 1 podcast\n/).to_stdout
      .and have_enqueued_job(Sponsors::ScanJob).with(waiting.id, anything, rescan: false).exactly(:once)
    expect(Sponsors::ScanJob).not_to have_been_enqueued.with(done.id, anything, anything)
    expect(Sponsors::ScanJob).not_to have_been_enqueued.with(removed.id, anything, anything)
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

  it "rescans every episode of one podcast" do
    episode = create(:episode, sponsor_scanned_at: 1.day.ago)

    expect { Rake::Task["sponsors:rescan"].invoke(episode.podcast.slug) }.to output(/Queued a rescan of 1 episode/).to_stdout
      .and have_enqueued_job(Sponsors::ScanJob).with(episode.podcast.id, [ episode.id ], rescan: true)
  end
end
