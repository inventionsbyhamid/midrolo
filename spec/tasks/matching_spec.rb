require "rails_helper"
require "rake"

RSpec.describe "rake matching:similar_backfill" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("matching:similar_backfill") }

  let(:task) { Rake::Task["matching:similar_backfill"] }
  let(:owner) { User.find_or_create_by!(email: User::SAMPLES_EMAIL) }

  def sample(slug, **attrs)
    create(:report, show: create(:show, user: owner), kind: "agent", status: "done", sample_slug: slug, **attrs)
  end

  before { task.reenable }

  it "finds the similar shows for the done samples that lack them, and skips the rest" do
    lacking = sample(Samples.slugs[0])
    sample(Samples.slugs[1], similar_podcasts: [ { "qloo_entity_id" => "q1", "name" => "Kept", "score" => 0.5, "podcast_id" => nil } ])
    allow(Research::SimilarPodcasts).to receive(:backfill).and_return(Array.new(10) { {} })

    expect { task.invoke }.to output(/#{Samples.slugs[0]}: 10 shows\n#{Samples.slugs[1]}: already has 1 show\n/).to_stdout
    expect(Research::SimilarPodcasts).to have_received(:backfill).once.with(lacking)
  end
end
