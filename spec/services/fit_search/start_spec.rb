require "rails_helper"

RSpec.describe FitSearch::Start do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:brand) { create(:brand, name: "Fieldnote Coffee", domain: "fieldnote.example") }
  let(:member) { create(:brand_member, user: user, brand: brand) }

  def start(**attrs) = described_class.call(member: member, attributes: { query: "Fieldnote Coffee" }.merge(attrs))

  it "saves a queued search for the member's brand and queues the job" do
    search = nil
    expect { search = start(website: "https://fieldnote.example/shop", categories: [ "food and beverage", "Rocketry" ], budget: "$1,500") }
      .to have_enqueued_job(FitSearchJob)

    expect(search).to have_attributes(user: user, brand: brand, query: "Fieldnote Coffee", status: "queued",
                                      website: "https://fieldnote.example/shop", categories: [ "Food & Beverage" ],
                                      budget_cents: 150_000)
  end

  it "falls back to the brand's domain for a website that isn't one, and reads junk budgets as none" do
    search = start(website: "not a site", budget: "lots")

    expect(search).to have_attributes(website: "fieldnote.example", budget_cents: nil)
  end

  it "refuses while runs are paused" do
    AppSettings.pause_runs!("maintenance")

    expect { start }.to raise_error(described_class::Refused, described_class::PAUSED_MESSAGE)
    expect(FitSearch.count).to eq(0)
  end

  it "holds unverified members to fewer searches a day than verified ones" do
    create_list(:fit_search, User::Brands::DAILY_SEARCHES[:unverified], user: user, brand: brand)

    expect { start }.to raise_error(described_class::Refused, /the most a day\. Verify your work email to run more\./)

    member.update!(verified_at: Time.current)
    expect { start }.not_to raise_error
  end

  it "doesn't count searches older than a day" do
    travel_to(25.hours.ago) { create_list(:fit_search, User::Brands::DAILY_SEARCHES[:unverified], user: user, brand: brand) }

    expect { start }.not_to raise_error
  end

  it "refuses a free account once its share of today's Qloo calls is spent" do
    allow_any_instance_of(Taste::CallGuard).to receive(:capped_spent?).and_return(true)

    expect { start }.to raise_error(described_class::Refused, FitSearch::Run::FREE_BUSY_MESSAGE)
  end

  it "raises on a blank query" do
    expect { start(query: " ") }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
