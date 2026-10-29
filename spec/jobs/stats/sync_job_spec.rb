require "rails_helper"

RSpec.describe Stats::SyncJob do
  include ActiveJob::TestHelper

  let(:owner) { create(:user) }
  let(:podcast) { create(:podcast, title: "The Founder's Ledger", feed_url: "https://feeds.example.com/ledger.xml") }
  let!(:owner_show) { create(:show, user: owner, podcast: podcast, verified_at: 1.day.ago) }
  let!(:session) { create(:service_session, platform: "spotify") }
  let(:connection) { create(:stat_connection, podcast: podcast, show: owner_show, user: owner, provider: "spotify") }

  before { podcast.update!(claimed_at: 1.day.ago) }

  def stub_fetch(*results)
    allow(Stats::PlatformFetch).to receive(:call).and_return(*results)
  end

  def run = described_class.perform_now(connection.id)

  def readings = podcast.stat_readings.where(source: "spotify").index_by(&:metric)

  describe "a pending invite" do
    it "turns active on the first fetch that works, and saves the numbers as verified" do
      stub_fetch(spotify_result)
      run

      expect(connection.reload).to have_attributes(status: "active", last_error: nil)
      expect(connection.activated_at).to be_present
      expect(connection.last_synced_at).to be_present
      expect(readings.keys).to include("streams_30d", "listeners_30d", "followers", "streams_all_time", "spotify_audience")
      expect(readings.values.map(&:trust).uniq).to eq([ "verified" ])
      expect(readings["listeners_30d"].value).to eq(2_140) # audience_listeners, never the listener-days sum
      expect(Stats::PlatformFetch).to have_received(:call).once # the 30 days had a breakdown
    end

    it "keeps waiting while the invite isn't accepted (no access yet)" do
      stub_fetch(fetch_error("forbidden"))
      run
      expect(connection.reload).to have_attributes(status: "pending_invite", last_error: described_class::NO_ACCESS_YET)
      expect(connection.last_checked_at).to be_present
    end

    it "keeps waiting through a failed fetch" do
      stub_fetch(fetch_error("failed", "Timed out"))
      run
      expect(connection.reload.status).to eq("pending_invite")
      expect(connection.last_error).to include("Timed out.")
    end

    it "gives up after the invite window, without fetching" do
      stub_fetch(spotify_result)
      connection.update!(created_at: (StatConnection::INVITE_WINDOW + 1.hour).ago)
      run
      expect(connection.reload).to have_attributes(status: "failed")
      expect(connection.last_error).to include("within 14 days")
      expect(Stats::PlatformFetch).not_to have_received(:call)
    end

    it "fetches nothing and keeps waiting while the podcast isn't claimed by its maker" do
      stub_fetch(spotify_result)
      unclaimed = create(:podcast)
      other = create(:user)
      draft = create(:stat_connection, podcast: unclaimed, user: other, show: create(:show, user: other, podcast: unclaimed))
      described_class.perform_now(draft.id)

      expect(draft.reload).to have_attributes(status: "pending_invite", last_error: /Claim this show first/)
      expect(Stats::PlatformFetch).not_to have_received(:call)
    end
  end

  describe "the ownership check" do
    it "is a mismatch when someone else owns the podcast, and reads nothing" do
      stub_fetch(spotify_result)
      connection.update!(status: "active", user: create(:user))
      run
      expect(connection.reload).to have_attributes(status: "mismatch", last_error: /Another account owns this show/)
      expect(Stats::PlatformFetch).not_to have_received(:call)
      expect(readings).to be_empty
    end

    it "is a mismatch when the platform's show is another show, and saves nothing" do
      stub_fetch(spotify_result(show_name: "Someone Else's Pod"))
      run
      expect(connection.reload.status).to eq("mismatch")
      expect(connection.last_error).to include("Someone Else's Pod").and include("Check the link")
      expect(readings).to be_empty
    end

    it "matches on the feed URL when the names differ" do
      stub_fetch(spotify_result(show_name: "Ledger (old name)", rss_url: "http://FEEDS.example.com/ledger.xml/"))
      run
      expect(connection.reload.status).to eq("active")
    end

    it "matches the title however it's punctuated" do
      stub_fetch(spotify_result(show_name: "the founders ledger"))
      run
      expect(connection.reload.status).to eq("active")
    end
  end

  describe "an active connection" do
    before { connection.update!(status: "active", activated_at: 3.days.ago) }

    it "is disconnected when access is removed, and keeps the numbers it had" do
      reading = create(:stat_reading, podcast: podcast, source: "spotify", metric: "followers", trust: "verified")
      stub_fetch(fetch_error("forbidden"))
      run
      expect(connection.reload).to have_attributes(status: "disconnected", last_error: /no longer has access/)
      expect(reading.reload).to be_persisted
    end

    it "is disconnected when the show is gone" do
      stub_fetch(fetch_error("not_found"))
      run
      expect(connection.reload.status).to eq("disconnected")
    end

    it "fails on any other error, to be tried again" do
      stub_fetch(fetch_error("failed", "Spotify answered 503"))
      run
      expect(connection.reload).to have_attributes(status: "failed", last_error: /Spotify answered 503\. We'll try again tomorrow/)
    end

    it "comes back to active from failed when a fetch works" do
      connection.update!(status: "failed", last_error: "x")
      stub_fetch(spotify_result)
      run
      expect(connection.reload).to have_attributes(status: "active", last_error: nil)
    end
  end

  describe "an expired service session" do
    it "pauses: the session is marked expired, the admins are told once, and the connection is unchanged" do
      create(:user, admin: true, email: "ops@example.com")
      stub_fetch(fetch_error("expired", "Spotify asked to sign in again."))

      expect { run }.to have_enqueued_mail(AdminMailer, :service_session_expired).once
      expect(session.reload).to have_attributes(status: "expired", last_error: "Spotify asked to sign in again.")
      expect(connection.reload).to have_attributes(status: "pending_invite", last_error: nil)

      expect { described_class.perform_now(connection.id) }.not_to have_enqueued_mail(AdminMailer, :service_session_expired)
      expect(Stats::PlatformFetch).to have_received(:call).once # the second run waits for a new session
    end

    it "doesn't mark a session an admin replaced while the fetch ran" do
      allow(Stats::PlatformFetch).to receive(:call) do
        session.update!(credentials: { "sp_dc" => "new" }.to_json, updated_at: 1.minute.from_now)
        fetch_error("expired")
      end
      run
      expect(session.reload.status).to eq("ok")
    end
  end

  describe "the audience" do
    it "asks for the last 12 months when 30 days had no breakdown" do
      longer = spotify_result(days: 365, breakdowns: { "age" => { "28-34" => 0.6, "35-44" => 0.4 } })
      stub_fetch(spotify_result(breakdowns: {}), longer)
      run

      expect(Stats::PlatformFetch).to have_received(:call).with(connection, session: session, days: 365)
      audience = readings["spotify_audience"]
      expect(audience.breakdown).to eq("age" => { "28-34" => 0.6, "35-44" => 0.4 })
      expect(audience.period_days).to eq(365)
      expect(audience.evidence["period_start"]).to eq((Time.now.utc.to_date - 365).iso8601)
    end

    it "saves an empty audience when 12 months have none either" do
      stub_fetch(spotify_result(breakdowns: {}), spotify_result(breakdowns: {}, days: 365))
      run
      expect(readings["spotify_audience"]).to have_attributes(breakdown: {}, period_days: 365)
    end

    it "keeps the last audience when the 12-month call fails" do
      create(:stat_reading, podcast: podcast, source: "spotify", metric: "spotify_audience", trust: "verified",
                            breakdown: { "age" => { "28-34" => 1.0 } }, captured_at: 2.days.ago)
      stub_fetch(spotify_result(breakdowns: {}), fetch_error("failed", "Timed out"))
      run
      expect(connection.reload.status).to eq("active")
      expect(readings["spotify_audience"].breakdown).to eq("age" => { "28-34" => 1.0 })
    end
  end

  it "refreshes the podcast's listing columns with plays per episode" do
    create(:episode, podcast: podcast, published_at: 3.days.ago)
    create(:episode, podcast: podcast, published_at: 10.days.ago)
    create(:episode, podcast: podcast, published_at: 90.days.ago) # outside the window
    stub_fetch(spotify_result)
    run

    expect(podcast.reload).to have_attributes(downloads_per_episode: 1_200, downloads_trust: "verified")
  end

  it "does nothing for a missing, disconnected or non-platform connection, or with no working session" do
    allow(Stats::PlatformFetch).to receive(:call)
    described_class.perform_now(0)
    connection.update!(status: "disconnected")
    run
    connection.update!(status: "active")
    session.update!(status: "expired")
    run
    expect(Stats::PlatformFetch).not_to have_received(:call)
  end
end
