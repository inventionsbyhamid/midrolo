require "rails_helper"
require "rake"

RSpec.describe "rake sponsors" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("sponsors:scan") }

  before { %w[sponsors:scan sponsors:rescan].each { |name| Rake::Task[name].reenable } }

  it "queues a scan for podcasts with unscanned episodes" do
    waiting = create(:episode).podcast
    done = create(:episode, sponsor_scanned_at: 1.day.ago).podcast
    removed = create(:episode, podcast: create(:podcast, status: "removed")).podcast

    expect { Rake::Task["sponsors:scan"].invoke }.to output(/Queued sponsor scans for 1 podcast\n/).to_stdout
      .and have_enqueued_job(Sponsors::ScanJob).with(waiting.id, anything, rescan: false).exactly(:once)
    expect(Sponsors::ScanJob).not_to have_been_enqueued.with(done.id, anything, anything)
    expect(Sponsors::ScanJob).not_to have_been_enqueued.with(removed.id, anything, anything)
  end

  it "rescans every episode of one podcast" do
    episode = create(:episode, sponsor_scanned_at: 1.day.ago)

    expect { Rake::Task["sponsors:rescan"].invoke(episode.podcast.slug) }.to output(/Queued a rescan of 1 episode/).to_stdout
      .and have_enqueued_job(Sponsors::ScanJob).with(episode.podcast.id, [ episode.id ], rescan: true)
  end
end
