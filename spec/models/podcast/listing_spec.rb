require "rails_helper"

RSpec.describe Podcast::Listing do
  describe ".listing_months" do
    it "is this month and the next five" do
      expect(Podcast.listing_months(Date.new(2026, 10, 30))).to eq(%w[2026-10 2026-11 2026-12 2027-01 2027-02 2027-03])
    end
  end

  describe ".listing_band" do
    it "names the range a figure falls in" do
      expect([ 0, 499, 500, 2_499, 9_999, 10_000, 1_000_000 ].map { |value| Podcast.listing_band(value) })
        .to eq([ "Under 500", "Under 500", "500 to 1,000", "1,000 to 2,500", "5,000 to 10,000", "10,000 and up", "10,000 and up" ])
      expect(Podcast.listing_band(nil)).to be_nil
    end
  end

  describe "the demo show" do
    it "is found by its guid, left out by not_demo, and never indexable whatever writes it" do
      demo = create(:podcast, :indexable, podcast_guid: Podcast::DEMO_GUID)
      other = create(:podcast, :indexable)
      guid = create(:podcast, podcast_guid: "another-guid")

      expect(demo).to be_demo
      expect(demo.reload.indexable).to be(false)
      demo.update!(indexable: true)
      expect(demo.reload.indexable).to be(false)
      expect(Podcast.demo).to contain_exactly(demo)
      expect(Podcast.not_demo).to contain_exactly(other, guid)
      expect(other.reload.indexable).to be(true)
    end
  end

  describe "#listing_downloads_reading" do
    let(:podcast) { create(:podcast) }

    it "picks what best_downloads_reading would, from the loaded readings without a query" do
      create(:stat_reading, podcast: podcast, source: "provided", trust: "provided", value: 900, captured_at: 1.day.ago)
      verified = create(:stat_reading, podcast: podcast, source: "platforms", trust: "verified", value: 2_100, captured_at: 3.days.ago)
      create(:stat_reading, podcast: podcast, source: "op3", trust: "verified", value: 5_000, captured_at: 2.days.ago,
                            expires_at: 1.hour.ago)
      create(:stat_reading, podcast: podcast, metric: "followers", source: "spotify", trust: "verified", value: 50_000)

      loaded = Podcast.includes(:stat_readings).find(podcast.id)
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
      reading = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { loaded.listing_downloads_reading }

      expect(reading).to eq(verified)
      expect(queries).to be_empty
      expect(podcast.listing_downloads_reading).to eq(podcast.best_downloads_reading)
    end
  end

  describe "#waiting_requests_count" do
    it "counts the requests that wait for a claim" do
      podcast = create(:podcast)
      create(:conversation, podcast: podcast, status: "waiting_for_claim")
      create(:conversation, podcast: podcast, status: "waiting_for_claim")
      create(:conversation, podcast: podcast, status: "declined", decline_reason: "Booked through the spring.")

      expect(podcast.waiting_requests_count).to eq(2)
    end
  end
end

RSpec.describe Show::Claiming do
  let(:podcast) { create(:podcast, owner_email: "Host@Example.com") }

  it "says where a workspace stands" do
    draft = create(:show, podcast: podcast)
    expect(draft.claim_status).to eq(:draft)

    owner = create(:show, podcast: podcast)
    owner.verify!(via: "admin")
    expect(owner.claim_status).to eq(:claimed)
    expect(draft.reload.claim_status).to eq(:managed_elsewhere)
  end

  it "matches the feed's owner address to a Google sign in only" do
    show = create(:show, podcast: podcast, user: create(:user, email: "host@example.com"))
    expect(show.owner_email_matches_user?).to be(true)
    expect(show.owner_email_matches_user?("other@example.com")).to be(false)
    expect(show.owner_email_matches_user?(nil)).to be(false)

    show.user.update!(provider: "github")
    expect(show.owner_email_matches_user?).to be(false)
  end
end
