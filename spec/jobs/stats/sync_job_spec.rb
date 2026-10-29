require "rails_helper"

RSpec.describe Stats::SyncJob do
  include ActiveJob::TestHelper

  let(:owner) { create(:user) }
  let(:podcast) { create(:podcast, title: "The Founder's Ledger", feed_url: "https://feeds.example.com/ledger.xml") }
  let!(:owner_show) { create(:show, user: owner, podcast: podcast, verified_at: 1.day.ago) }
  let!(:session) { create(:service_session, platform: "spotify") }
  let(:connection) { create(:stat_connection, podcast: podcast, show: owner_show, user: owner, provider: "spotify") }

  before do
    podcast.update!(claimed_at: 1.day.ago)
    allow_stats_runs # back-to-back runs here; "the throttle" below uses the real one
  end

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

    it "saves nothing when an admin disconnected it while the platform answered" do
      allow(Stats::PlatformFetch).to receive(:call) do
        StatConnection.where(id: connection.id).update_all(status: "disconnected", last_error: StatConnection::REJECTED_MESSAGE)
        spotify_result
      end
      run
      expect(Stats::PlatformFetch).to have_received(:call)
      expect(connection.reload).to have_attributes(status: "disconnected", last_error: StatConnection::REJECTED_MESSAGE)
      expect(readings).to be_empty
    end

    it "saves nothing when the owner removed it while the platform answered" do
      allow(Stats::PlatformFetch).to receive(:call) do
        StatConnection.where(id: connection.id).delete_all
        spotify_result
      end
      run
      expect(Stats::PlatformFetch).to have_received(:call)
      expect(readings).to be_empty
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
      expect(connection.last_error).to include("Check the link")
      expect(connection.last_error).not_to include("Someone Else") # never names a show that isn't theirs
      expect(readings).to be_empty
    end

    # Review H3: Spotify's metadata usually has no RSS URL, so the title is the only check. A clone that copies a real
    # show's title and points its connection at the real show's id must never get the real show's verified numbers.
    describe "a same-titled clone of a real show" do
      let(:attacker) { create(:user) }
      let(:clone) { create(:podcast, title: "The Founder's Ledger", feed_url: "https://evil.example.com/ledger.xml", claimed_at: 1.day.ago) }
      let(:clone_show) { create(:show, user: attacker, podcast: clone, verified_at: 1.day.ago) }
      let(:clone_connection) do
        create(:stat_connection, podcast: clone, show: clone_show, user: attacker, provider: "spotify", external_id: "4rOoJ6Egrf8K2IrywzwOMk")
      end
      let(:clone_readings) { clone.stat_readings.where(source: "spotify") }

      it "copies no numbers onto the clone by the title alone, and leaves it for a person to check" do
        stub_fetch(spotify_result)
        described_class.perform_now(clone_connection.id)

        expect(clone_connection.reload).to have_attributes(status: "mismatch", last_error: Stats::Ownership::NEEDS_REVIEW)
        expect(clone_readings).to be_empty
      end

      it "leaves the real show held for review too while the names collide, and verifies whichever an admin approves" do
        stub_fetch(spotify_result)
        clone # the clone exists, so the real show's title is no longer unique
        run
        expect(connection.reload).to have_attributes(status: "mismatch", last_error: Stats::Ownership::NEEDS_REVIEW)
        expect(readings).to be_empty

        connection.update!(approved_at: Time.current)
        run
        expect(connection.reload).to have_attributes(status: "active", last_error: nil)
        expect(readings).not_to be_empty
      end

      it "still verifies by the feed, which a clone can't copy" do
        stub_fetch(spotify_result(rss_url: "https://feeds.example.com/ledger.xml"))
        clone
        run
        expect(connection.reload.status).to eq("active")
      end

      it "keeps a show verified before the clone appeared" do
        stub_fetch(spotify_result)
        run
        expect(connection.reload.status).to eq("active")

        clone
        run
        expect(connection.reload.status).to eq("active")
      end

      it "can't point a second podcast at a platform show another podcast's connection holds, in any state but disconnected" do
        connection.update!(external_id: "4rOoJ6Egrf8K2IrywzwOMk", status: "failed")
        expect { clone_connection }.to raise_error(ActiveRecord::RecordInvalid, /already connected to another Midrolo page/)

        connection.update!(status: "disconnected")
        expect(clone_connection).to be_persisted
      end
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

    # Final review N9: an admin's Reject (or the owner's Disconnect) while a fetch runs that then fails or is refused.
    it "stays disconnected when it was rejected while a fetch that failed or was refused ran" do
      [ fetch_error("failed", "Spotify answered 503"), fetch_error("forbidden") ].each do |outcome|
        connection.update!(status: "active")
        allow(Stats::PlatformFetch).to receive(:call) do
          StatConnection.where(id: connection.id).update_all(status: "disconnected", last_error: StatConnection::REJECTED_MESSAGE)
          outcome
        end
        run
        expect(connection.reload).to have_attributes(status: "disconnected", last_error: StatConnection::REJECTED_MESSAGE)
      end
    end

    it "writes nothing when the owner removed it while a fetch that failed ran" do
      allow(Stats::PlatformFetch).to receive(:call) do
        StatConnection.where(id: connection.id).delete_all
        fetch_error("failed", "Spotify answered 503")
      end
      expect { run }.not_to raise_error
      expect(StatConnection.exists?(connection.id)).to be(false)
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
    def audience_reading(captured_at)
      create(:stat_reading, podcast: podcast, source: "spotify", metric: "spotify_audience", trust: "verified", value: 900,
                            period_days: 365, breakdown: { "age" => { "28-34" => 1.0 } }, captured_at: captured_at)
    end

    it "keeps the last audience when 30 days had no breakdown, and asks for 12 months in a run of its own" do
      audience_reading(8.days.ago)
      stub_fetch(spotify_result(breakdowns: {}))

      expect { run }.to have_enqueued_job(Stats::AudienceJob).with(connection.id)
      expect(Stats::PlatformFetch).to have_received(:call).once # not a second run straight after the first
      expect(connection.reload.status).to eq("active")
      expect(readings["spotify_audience"]).to have_attributes(breakdown: { "age" => { "28-34" => 1.0 } }, period_days: 365)
    end

    it "asks for 12 months at most once a week" do
      audience_reading(2.days.ago)
      stub_fetch(spotify_result(breakdowns: {}))
      expect { run }.not_to have_enqueued_job(Stats::AudienceJob)
      expect(readings["spotify_audience"].captured_at).to be < 1.day.ago # kept, not emptied
    end

    it "saves the 30 days' breakdown when there is one, and asks nothing more" do
      audience_reading(8.days.ago)
      stub_fetch(spotify_result)
      expect { run }.not_to have_enqueued_job(Stats::AudienceJob)
      expect(readings["spotify_audience"]).to have_attributes(period_days: 30, breakdown: include("age", "gender", "country"))
    end
  end

  # Midrolo's own platform accounts stay light: every run goes through Stats::Throttle.
  describe "the throttle" do
    before { allow(Stats::Throttle).to receive(:reserve).and_call_original }

    def scheduled_syncs = enqueued_jobs.select { |job| job["job_class"] == "Stats::SyncJob" }

    it "records each run, and waits its turn after one: enqueued again for the time it's given, nothing fetched" do
      stub_fetch(spotify_result)
      run
      expect(session.reload.run_log.size).to eq(1)
      expect(session.next_run_at).to be_between(29.seconds.from_now, 46.seconds.from_now)

      checked = connection.reload.last_checked_at
      expect { run } # Check now, right after
        .to have_enqueued_job(described_class).with(connection.id, anything).at(a_value_within(1.second).of(session.next_run_at))
      expect(Stats::PlatformFetch).to have_received(:call).once
      expect(connection.reload.last_checked_at).to eq(checked)
    end

    it "never waits less than a few seconds, so the copy running now has let go of the connection" do
      session.update_columns(next_run_at: 1.second.from_now)
      expect { run }.to have_enqueued_job(described_class).at(a_value_within(1.second).of(described_class::MIN_WAIT.from_now))
    end

    it "keeps the sync after a rate limit: the platform cools down, the connection is left as it was, and it asks again after" do
      stub_fetch(fetch_error("rate_limited", "Spotify answered 429.", retry_after: 600))
      requested = 1.minute.ago
      expect { described_class.perform_now(connection.id, requested) }
        .to have_enqueued_job(described_class).with(connection.id, a_value_within(0.001).of(requested))
                                              .at(a_value_within(1.second).of(600.seconds.from_now))

      expect(session.reload).to have_attributes(status: "ok", rate_limits_in_a_row: 1)
      expect(session.cooldown_until).to be_within(1.second).of(600.seconds.from_now)
      expect(connection.reload).to have_attributes(status: "pending_invite", last_error: nil, last_checked_at: nil)
    end

    it "has nothing to do once the connection was checked after the sync was asked for" do
      connection.update!(last_checked_at: 1.minute.ago)
      allow(Stats::PlatformFetch).to receive(:call)
      described_class.perform_now(connection.id, 5.minutes.ago)
      expect(Stats::PlatformFetch).not_to have_received(:call)
      expect(session.reload.run_log).to be_empty
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
