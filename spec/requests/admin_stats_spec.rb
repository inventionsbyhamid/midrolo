require "rails_helper"

RSpec.describe "Admin stats" do
  include ActiveJob::TestHelper

  let(:admin) { create(:user, admin: true, email: "ops@example.com") }
  let(:cookie) { "AQDsecretSpotifyCookie0123456789" }

  around do |example|
    saved = ENV.values_at("ADMIN_USERNAME", "ADMIN_PASSWORD")
    ENV.delete("ADMIN_USERNAME")
    ENV.delete("ADMIN_PASSWORD")
    example.run
  ensure
    ENV["ADMIN_USERNAME"], ENV["ADMIN_PASSWORD"] = saved
  end

  it "is not found for anyone but an admin" do
    user = create(:user)
    [ -> { get admin_service_sessions_path }, -> { get admin_stat_connections_path },
      -> { patch admin_service_session_path("spotify"), params: { credentials: { sp_dc: cookie } } },
      -> { post test_admin_service_session_path("spotify"), params: { show_id: "2nel53b14wqMRDx2toN28f" } },
      -> { patch limits_admin_service_sessions_path, params: { limits: { stats_min_gap_seconds: "60" } } },
      -> { post approve_admin_stat_connection_path(create(:stat_connection)) },
      -> { post reject_admin_stat_connection_path(create(:stat_connection, status: "mismatch", last_error: Stats::Ownership::NEEDS_REVIEW)) } ].each do |request|
      sign_in user # a 404 doesn't keep the test sign-in for the next request
      request.call
      expect(response).to have_http_status(:not_found)
    end
    expect(ServiceSession.count).to eq(0)
    expect(StatConnection.where(status: "disconnected")).to be_empty
  end

  context "as an admin" do
    before { sign_in admin }

    it "saves a session from the form and never shows it, logs it or puts it back in a form" do
      log = StringIO.new
      allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(log))

      patch admin_service_session_path("spotify"), params: { credentials: { sp_dc: cookie, sp_key: "" }, expires_hint: "2027-01-31" }
      expect(response).to redirect_to(admin_service_sessions_path)
      expect(flash[:notice]).to eq("Spotify for Creators session saved. It won't be shown again.")
      session = ServiceSession.find_by!(platform: "spotify")
      expect(JSON.parse(session.credentials)).to eq("sp_dc" => cookie)
      expect(session.expires_hint.to_date).to eq(Date.new(2027, 1, 31))

      get admin_service_sessions_path
      expect(response.body).to include("Working").and include("Replace the session")
      expect(response.body).not_to include(cookie)
      expect(response.body).to include('type="password"')
      expect(log.string).not_to include(cookie)
      expect(ServiceSession.find_by!(platform: "spotify").inspect).not_to include(cookie)
    end

    it "refuses a session missing a required key, without echoing what was typed" do
      patch admin_service_session_path("apple"), params: { credentials: { myacinfo: cookie } }
      expect(response).to redirect_to(admin_service_sessions_path)
      expect(flash[:alert]).to eq("Paste itctx to save the Apple Podcasts session.")
      follow_redirect!
      expect(response.body).not_to include(cookie)
      expect(ServiceSession.count).to eq(0)
    end

    it "404s an unknown platform" do
      patch admin_service_session_path("youtube"), params: { credentials: { key: "x" } }
      expect(response).to have_http_status(:not_found)
    end

    describe "test fetch" do
      let!(:session) { create(:service_session, platform: "spotify", credentials: { "sp_dc" => cookie }.to_json) }
      let(:connection) { create(:stat_connection, provider: "spotify", external_id: "4rOoJ6Egrf8K2IrywzwOMk") }

      it "fetches a connection now, shows what came back and saves no numbers" do
        allow(Stats::PlatformFetch).to receive(:call).and_return(spotify_result)
        post test_admin_service_session_path("spotify"), params: { connection_id: connection.id }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Worked").and include("The Founder&#39;s Ledger").and include("48,000")
        expect(response.body).not_to include(cookie)
        expect(StatReading.count).to eq(0)
        expect(session.reload.last_ok_at).to be_present
      end

      it "fetches a show id typed in, and marks an expired session" do
        allow(Stats::PlatformFetch).to receive(:call).and_return(fetch_error("expired", "Spotify asked to sign in again."))
        post test_admin_service_session_path("spotify"), params: { show_id: "https://open.spotify.com/show/2nel53b14wqMRDx2toN28f" }

        expect(Stats::PlatformFetch).to have_received(:call) do |tested, **|
          expect(tested).to have_attributes(provider: "spotify", external_id: "2nel53b14wqMRDx2toN28f", persisted?: false)
        end
        expect(response.body).to include("Expired").and include("Spotify asked to sign in again.")
        expect(session.reload.status).to eq("expired")
      end

      it "waits for the platform's limits like any other run" do
        session.update_columns(next_run_at: 2.minutes.from_now)
        allow(Stats::PlatformFetch).to receive(:call)
        post test_admin_service_session_path("spotify"), params: { connection_id: connection.id }

        expect(response).to redirect_to(admin_service_sessions_path(anchor: "spotify"))
        expect(flash[:alert]).to start_with("Not yet: Spotify's limits allow the next run at ")
        expect(Stats::PlatformFetch).not_to have_received(:call)
      end

      it "counts as a run, and a rate limit cools the platform down" do
        allow(Stats::PlatformFetch).to receive(:call).and_return(fetch_error("rate_limited", "Spotify answered 429 on metadata.", retry_after: 900))
        post test_admin_service_session_path("spotify"), params: { connection_id: connection.id }

        expect(response.body).to include("Rate limited").and include("Spotify answered 429 on metadata.").and include("Cooling down")
        expect(session.reload).to have_attributes(status: "ok", rate_limits_in_a_row: 1, failures_in_a_row: 1)
        expect(session.run_log.size).to eq(1)
      end

      # The helper's fresh Spotify token goes into the session's credentials and nowhere a person can see it.
      it "keeps a fresh token out of the page and the log" do
        token = "BQfreshTokenFromTheHelper-0123456789"
        log = StringIO.new
        allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(log))
        status = instance_double(Process::Status, success?: true, exitstatus: 0)
        answer = JSON.generate(spotify_result.merge("token" => { "value" => token, "expires_at" => 1.hour.from_now.utc.iso8601 }))
        allow(Open3).to receive(:popen3) do |*, **, &block|
          block.call(StringIO.new, StringIO.new(answer), StringIO.new(""), double("waiter", join: true, value: status, pid: 1))
        end

        post test_admin_service_session_path("spotify"), params: { connection_id: connection.id }
        result_page = response.body
        expect(result_page).to include("Worked")
        get admin_service_sessions_path

        expect(JSON.parse(session.reload.credentials)["bearer_token"]).to eq(token)
        expect(result_page + response.body + log.string).not_to include(token)
      end

      it "asks for a connection or a show id" do
        post test_admin_service_session_path("spotify"), params: { show_id: "nope" }
        expect(flash[:alert]).to eq("Choose a connection or enter a show id.")
      end
    end

    describe "limits" do
      def throttle_rows(platform)
        page = Nokogiri::HTML(response.body)
        page.css("##{platform}_throttle dt").map { |dt| dt.text.squish }.zip(page.css("##{platform}_throttle dd").map { |dd| dd.text.squish }).to_h
      end

      it "shows each platform's runs, next allowed run, cooldown, failures and last rate limit" do
        create(:service_session, platform: "spotify", run_log: [ 5.minutes.ago.to_i, 3.hours.ago.to_i ], failures_in_a_row: 2,
                                 cooldown_until: 1.hour.from_now, last_rate_limited_at: 10.minutes.ago)
        get admin_service_sessions_path

        rows = throttle_rows("spotify")
        expect(rows).to include("Runs in the last hour" => "1 of 40", "Runs in the last 24 hours" => "2 of 300",
                                "Failed runs in a row" => "2")
        expect(rows["Cooldown until"]).to end_with("UTC")
        expect(rows["Next run allowed"]).to eq(rows["Cooldown until"])
        expect(rows["Last rate limited"]).to end_with("UTC")
        expect(response.body).to include("Cooling down")
      end

      it "saves new limits" do
        patch limits_admin_service_sessions_path, params: { limits: { stats_min_gap_seconds: "60", stats_gap_jitter_seconds: "20",
                                                                      stats_runs_per_hour: "30", stats_runs_per_day: "200" } }
        expect(response).to redirect_to(admin_service_sessions_path(anchor: "limits"))
        expect(flash[:notice]).to eq("Limits saved.")
        expect(Stats::Limits.current).to have_attributes(min_gap: 60, jitter: 20, per_hour: 30, per_day: 200)

        get admin_service_sessions_path
        expect(Nokogiri::HTML(response.body).at_css("input[name='limits[stats_min_gap_seconds]']")["value"]).to eq("60")
      end

      it "refuses limits that aren't allowed, and shows what was typed" do
        patch limits_admin_service_sessions_path, params: { limits: { stats_min_gap_seconds: "1", stats_gap_jitter_seconds: "15",
                                                                      stats_runs_per_hour: "40", stats_runs_per_day: "300" } }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Seconds between runs must be a whole number from 10 to 3600.")
        expect(Nokogiri::HTML(response.body).at_css("input[name='limits[stats_min_gap_seconds]']")["value"]).to eq("1")
        expect(Stats::Limits.current.min_gap).to eq(30)
      end
    end

    it "lists pending invites oldest first, with who connected them, and syncs one on request" do
      newer = create(:stat_connection, status: "pending_invite", created_at: 1.hour.ago, podcast: create(:podcast, title: "Newer Pod"),
                                       user: create(:user, email: "new@example.com"))
      older = create(:stat_connection, status: "pending_invite", created_at: 3.days.ago, podcast: create(:podcast, title: "Older Pod"),
                                       user: create(:user, email: "old@example.com"))
      create(:stat_connection, status: "mismatch", last_error: "Not the same show")

      get admin_stat_connections_path
      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body.index("Older Pod")).to be < body.index("Newer Pod")
      expect(body).to include("old@example.com", "3 days", "Not the same show", "https://open.spotify.com/show/#{older.external_id}")
      expect(body).to include("Syncs are paused for Spotify and Apple Podcasts")

      expect { post check_admin_stat_connection_path(older) }.to have_enqueued_job(Stats::SyncJob).with(older.id)
    end

    it "approves a connection held because another show has the same name, and syncs it at once" do
      held = create(:stat_connection, status: "mismatch", last_error: Stats::Ownership::NEEDS_REVIEW,
                                      podcast: create(:podcast, title: "Twin Name Pod"))
      other = create(:stat_connection, status: "mismatch", last_error: "Not the same show")

      get admin_stat_connections_path
      page = Nokogiri::HTML(response.body)
      expect(page.css("form[action='#{approve_admin_stat_connection_path(held)}']")).to be_present
      expect(page.css("form[action='#{approve_admin_stat_connection_path(other)}']")).to be_empty

      expect { post approve_admin_stat_connection_path(held) }.to have_enqueued_job(Stats::SyncJob).with(held.id)
      expect(held.reload.approved_at).to be_present
      expect(flash[:notice]).to eq("Approved. Syncing Twin Name Pod now.")
    end

    describe "reject" do
      let(:podcast) { create(:podcast, :claimed, title: "Twin Name Pod") }
      let(:owner) { create(:user, email: "maker@example.com") }
      let!(:held) do
        create(:stat_connection, status: "mismatch", last_error: Stats::Ownership::NEEDS_REVIEW, podcast: podcast,
                                 user: owner, show: create(:show, user: owner, podcast: podcast, verified_at: Time.current),
                                 external_id: "2nel53b14wqMRDx2toN28f")
      end

      it "shows Reject next to Approve, for connections held for review only" do
        other = create(:stat_connection, status: "mismatch", last_error: "Not the same show")

        get admin_stat_connections_path
        page = Nokogiri::HTML(response.body)
        expect(page.css("form[action='#{reject_admin_stat_connection_path(held)}'] button").map(&:text)).to eq([ "Reject" ])
        expect(page.css("form[action='#{reject_admin_stat_connection_path(other)}']")).to be_empty
      end

      it "disconnects it with a note, takes that platform's numbers off the page and frees the platform show" do
        create(:stat_reading, podcast: podcast, source: "spotify", trust: "verified", metric: "streams_30d", value: 900)
        create(:stat_reading, podcast: podcast, source: "platforms", trust: "verified", value: 225)
        apple = create(:stat_reading, podcast: podcast, source: "apple", trust: "verified", metric: "followers", value: 40)
        podcast.refresh_listing!
        expect(podcast.reload).to have_attributes(downloads_per_episode: 225, downloads_trust: "verified")

        expect { post reject_admin_stat_connection_path(held) }.not_to have_enqueued_job(Stats::SyncJob)
        expect(response).to redirect_to(admin_stat_connections_path)
        expect(flash[:notice]).to eq("Rejected. Twin Name Pod's Spotify connection is disconnected.")

        expect(held.reload).to have_attributes(status: "disconnected", last_error: StatConnection::REJECTED_MESSAGE,
                                               approved_at: nil, last_checked_at: be_present)
        expect(podcast.stat_readings.reload).to contain_exactly(apple)
        expect(podcast.reload).to have_attributes(downloads_per_episode: nil, downloads_trust: nil)

        real = create(:stat_connection, podcast: create(:podcast), provider: "spotify", external_id: held.external_id)
        expect(real).to be_persisted
      end

      it "tells the maker on their Stats screen, without saying the platform removed access" do
        post reject_admin_stat_connection_path(held)

        sign_in owner
        get show_stats_path(held.show)
        card = Nokogiri::HTML(response.body).at_css("#spotify")
        expect(card.text.squish).to include("Stopped", StatConnection::REJECTED_MESSAGE)
        expect(card.text).not_to include("access was removed", "Access removed")
        expect(card.css("input[type='submit']").map { |button| button["value"] }).to include("I've invited Midrolo")
      end

      it "changes nothing once it isn't held for review" do
        held.update!(status: "active", last_error: nil, approved_at: Time.current)
        reading = create(:stat_reading, podcast: podcast, source: "spotify", trust: "verified", metric: "followers", value: 12)

        post reject_admin_stat_connection_path(held)
        expect(response).to redirect_to(admin_stat_connections_path)
        expect(flash[:alert]).to eq("That connection isn't waiting for review any more.")
        expect(held.reload.status).to eq("active")
        expect(reading.reload).to be_persisted
      end
    end

    it "shows the stats panel on the dashboard" do
      create(:service_session, platform: "spotify", status: "expired")
      create(:stat_connection, status: "pending_invite")
      get admin_root_path
      expect(response.body).to include("Verified stats").and include("Expired, syncs paused").and include("1 pending invite")
    end
  end
end
