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
      -> { post test_admin_service_session_path("spotify"), params: { show_id: "2nel53b14wqMRDx2toN28f" } } ].each do |request|
      sign_in user # a 404 doesn't keep the test sign-in for the next request
      request.call
      expect(response).to have_http_status(:not_found)
    end
    expect(ServiceSession.count).to eq(0)
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

      it "asks for a connection or a show id" do
        post test_admin_service_session_path("spotify"), params: { show_id: "nope" }
        expect(flash[:alert]).to eq("Choose a connection or enter a show id.")
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

    it "shows the stats panel on the dashboard" do
      create(:service_session, platform: "spotify", status: "expired")
      create(:stat_connection, status: "pending_invite")
      get admin_root_path
      expect(response.body).to include("Verified stats").and include("Expired, syncs paused").and include("1 pending invite")
    end
  end
end
