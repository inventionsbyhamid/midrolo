require "rails_helper"

# T0 gave each lane its classes with their final signatures (build spec section 10), and the lanes filled them. These
# pin the signatures and the queues.
RSpec.describe "Marketplace stubs" do
  it "has the jobs on their queues, with their arguments" do
    expect(Catalog::ArtworkJob.new(1).queue_name).to eq("artwork")
    expect(Catalog::RefreshDueJob.new.queue_name).to eq("catalog")
    expect(Sponsors::ScanJob.new(1, [ 2 ]).queue_name).to eq("sponsors")
    expect([ Stats::SyncJob.new(1), Stats::SyncDueJob.new, Stats::ExpireReadingsJob.new ].map(&:queue_name)).to all(eq("stats"))
    expect(Sponsors::ScanJob.new(1, [ 2 ]).priority).to eq(20)
    expect(Stats::SyncJob.new(1).priority).to eq(10)

    expect { Catalog::ArtworkJob.perform_now(0) }.not_to raise_error
    expect { Catalog::RefreshDueJob.perform_now }.not_to raise_error
    expect { Sponsors::ScanJob.perform_now(0, []) }.not_to raise_error
    expect { Stats::SyncJob.perform_now(0) }.not_to raise_error
  end

  it "has the services, answering as their lanes will" do
    result = Catalog::LazyAdd.call("darknet diaries")
    expect([ result.found, result.added, result.podcasts ]).to eq([ [], [], [] ])
    expect(Sponsors::History.for(build(:podcast))).to eq([])
    expect(Sponsors::History.for_brand(build(:brand))).to eq([])
    # Filled by lane L5: with no service session there is nothing to ask.
    expect(Stats::PlatformFetch.call(build(:stat_connection))).to include("ok" => false, "error" => "unavailable")
    expect { Conversations::ClaimHandoff.call(build(:podcast)) }.not_to raise_error
  end

  it "matches a Qloo entity to the podcast linked to it" do
    podcast = create(:podcast, qloo_entity_id: "Q-1")
    entity = Taste::Entity.new(id: "Q-1", name: podcast.title, type: :podcast, tags: [], affinity: nil, popularity: nil,
                               image_url: nil, website: nil, description: nil, properties: {})
    expect(Catalog::QlooMatch.call(entity)).to eq(podcast)
    expect(Catalog::QlooMatch.call("Q-2")).to be_nil
  end

  it "has the trust badge helper" do
    expect(ApplicationController.helpers.trust_badge("verified")).to include("Verified")
    expect(ApplicationController.helpers.trust_badge(build(:stat_reading, trust: "provided"))).to include("Provided")
  end

  it "draws each lane's routes file, and has each lane's page partials and admin panels" do
    %w[catalog claims stats brands conversations].each do |name|
      expect(Rails.root.join("config/routes/#{name}.rb")).to exist
    end
    # Every lane has filled its partials now; their own specs render them (spec/views/podcasts, spec/requests).
    %w[numbers sponsors rates claim request save similar audience].each do |name|
      expect(Rails.root.join("app/views/podcasts/_#{name}.html.erb")).to exist
    end
    Admin::DashboardController::PANELS.each do |name|
      expect(Rails.root.join("app/views/admin/dashboard/_#{name}.html.erb")).to exist
    end
  end
end
