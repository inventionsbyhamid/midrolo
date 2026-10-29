require "rails_helper"
require "rake"

RSpec.describe "rake catalog" do
  include ActiveJob::TestHelper

  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("catalog:seed") }

  before do
    Podcasts::Directory.reset!
    %w[catalog:seed catalog:refresh catalog:add].each { |name| Rake::Task[name].reenable }
  end

  describe "catalog:seed" do
    it "seeds to the target given, and says how it went" do
      allow(Catalog::SeedFromQloo).to receive(:call).and_call_original
      expect { Rake::Task["catalog:seed"].invoke("2") }.to output(/2 linked to Qloo.*stopped: target/).to_stdout
      expect(Catalog::SeedFromQloo).to have_received(:call).with(hash_including(target: 2))
      expect(Podcast.where.not(qloo_entity_id: nil).count).to eq(2)
    end

    it "refuses a target that isn't a positive number" do
      expect { Rake::Task["catalog:seed"].invoke("0") }.to raise_error(SystemExit).and output(/at least 1/).to_stderr
      Rake::Task["catalog:seed"].reenable
      expect { Rake::Task["catalog:seed"].invoke("lots") }.to raise_error(ArgumentError)
    end
  end

  describe "catalog:refresh" do
    it "queues podcasts never read at low priority, then the due ones" do
      never = create(:podcast, next_fetch_at: nil)
      due = create(:podcast, next_fetch_at: 1.hour.ago)
      create(:podcast, next_fetch_at: nil, status: "removed")

      expect { Rake::Task["catalog:refresh"].invoke }.to output(/queued 1 never read/).to_stdout
      expect(Catalog::IngestPodcastJob).to have_been_enqueued.with(never.id).at_priority(20)
      expect(Catalog::IngestPodcastJob).to have_been_enqueued.with(due.id).at_priority(10)
    end
  end

  describe "catalog:add" do
    it "adds a show by name and reads its feed at once" do
      expect { Rake::Task["catalog:add"].invoke("Cold Case Cafe") }.to output(/added: Cold Case Cafe.*active, \d+ episodes/m).to_stdout
      expect(Podcast.find_by(title: "Cold Case Cafe").episodes).to be_present
    end

    it "keeps a name with commas whole" do
      allow(Catalog::AddShow).to receive(:call).and_return(Catalog::AddShow::Result.new(podcast: nil, created: false, others: [], error: "nope"))
      expect { Rake::Task["catalog:add"].invoke("Tea, Cake", " and Talk") }.to raise_error(SystemExit).and output(/nope/).to_stderr
      expect(Catalog::AddShow).to have_received(:call).with("Tea, Cake, and Talk")
    end

    it "explains a Spotify link" do
      expect { Rake::Task["catalog:add"].invoke("https://open.spotify.com/show/2nel53b14wqMRDx2toN28f") }
        .to raise_error(SystemExit).and output(/RSS feed URL/).to_stderr
    end
  end
end
