require "rails_helper"

RSpec.describe "Stats screen" do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:podcast) { create(:podcast, title: "The Founder's Ledger", apple_id: 1_234_567_890) }
  let(:show) { create(:show, user: user, podcast: podcast) }
  let(:spotify_link) { "https://open.spotify.com/show/2nel53b14wqMRDx2toN28f?si=x" }

  def claim!
    show.update!(verified_at: Time.current)
    podcast.update!(claimed_at: Time.current)
  end

  it "requires sign in" do
    get show_stats_path(show)
    expect(response).to redirect_to("/users/sign_in")
  end

  context "when signed in" do
    before { sign_in user }

    it "404s for another user's show, on every action" do
      other = create(:show)
      connection = create(:stat_connection, podcast: other.podcast, show: other, user: other.user)
      [ -> { get show_stats_path(other) },
        -> { patch provided_show_stats_path(other), params: { downloads_per_episode: "10" } },
        -> { post show_stat_connections_path(other), params: { provider: "spotify", show_link: spotify_link } },
        -> { post check_show_stat_connection_path(other, connection) },
        -> { delete show_stat_connection_path(other, connection) } ].each do |request|
        sign_in user
        request.call
        expect(response).to have_http_status(:not_found)
      end
      expect(connection.reload).to be_persisted
    end

    it "shows both platforms with the invite steps and the address to invite" do
      claim!
      get show_stats_path(show)

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("Spotify", "Apple Podcasts", "stats@midrolo.com", "Analytics", "Analyst", "I&#39;ve invited Midrolo")
      expect(body).to include("https://podcasts.apple.com/podcast/id1234567890") # the Apple id the catalog knows
      expect(body).to include("Numbers provided by the show")
      expect(body).not_to include("isn't claimed yet")
    end

    it "says a draft workspace's numbers count once the show is claimed" do
      get show_stats_path(show)
      expect(response.body).to include("This show isn't claimed yet").and include(new_show_verification_path(show))
    end

    describe "I've invited Midrolo" do
      before { claim! }

      it "records a pending invite with the show id from the link, and checks at once" do
        expect { post show_stat_connections_path(show), params: { provider: "spotify", show_link: spotify_link } }
          .to have_enqueued_job(Stats::SyncJob)
        connection = podcast.stat_connections.sole
        expect(connection).to have_attributes(provider: "spotify", external_id: "2nel53b14wqMRDx2toN28f", status: "pending_invite",
                                              user: user, show: show)
        expect(response).to redirect_to(show_stats_path(show, anchor: "spotify"))

        follow_redirect!
        expect(response.body).to include("Waiting for access").and include("We check every 15 minutes")
      end

      it "refuses a link without a show id" do
        post show_stat_connections_path(show), params: { provider: "spotify", show_link: "https://open.spotify.com/episode/x" }
        expect(flash[:alert]).to include("Paste your show's Spotify link")
        post show_stat_connections_path(show), params: { provider: "youtube", show_link: "x" }
        expect(flash[:alert]).to eq("Choose Spotify or Apple Podcasts.")
        expect(StatConnection.count).to eq(0)
      end

      it "starts over from a failed or disconnected connection" do
        old = create(:stat_connection, podcast: podcast, show: show, user: user, status: "disconnected", external_id: "old")
        post show_stat_connections_path(show), params: { provider: "spotify", show_link: spotify_link }
        expect(StatConnection.exists?(old.id)).to be(false)
        expect(podcast.stat_connections.sole).to have_attributes(status: "pending_invite", external_id: "2nel53b14wqMRDx2toN28f")
      end

      it "refuses a platform show another page's connection holds, without naming that page" do
        other = create(:podcast, title: "Someone Else's Pod")
        create(:stat_connection, podcast: other, provider: "spotify", external_id: "2nel53b14wqMRDx2toN28f", status: "active")

        post show_stat_connections_path(show), params: { provider: "spotify", show_link: spotify_link }
        expect(flash[:alert]).to eq("This show is already connected to another Midrolo page.")
        expect(flash[:alert]).not_to include("Someone Else")
        expect(podcast.stat_connections).to be_empty
      end

      it "takes the platform show over from a draft's connection on another page that never counted, which says why it stopped" do
        squatter = create(:user)
        other = create(:podcast, title: "Someone Else's Pod")
        draft = create(:stat_connection, podcast: other, user: squatter, show: create(:show, user: squatter, podcast: other),
                                         provider: "spotify", external_id: "2nel53b14wqMRDx2toN28f", status: "mismatch")

        post show_stat_connections_path(show), params: { provider: "spotify", show_link: spotify_link }
        expect(podcast.stat_connections.sole).to have_attributes(status: "pending_invite", external_id: "2nel53b14wqMRDx2toN28f")
        expect(draft.reload).to have_attributes(status: "disconnected", last_error: StatConnection::RELEASED_MESSAGE)
      end

      it "says a connection held for a name check is being checked" do
        create(:stat_connection, podcast: podcast, show: show, user: user, status: "mismatch",
                                 last_error: Stats::Ownership::NEEDS_REVIEW)
        get show_stats_path(show)
        expect(response.body).to include("Being checked", "Midrolo will check it by hand")
      end

      it "replaces a connection another account left on the owner's podcast" do
        stranger = create(:user)
        create(:stat_connection, podcast: podcast, user: stranger, show: create(:show, user: stranger, podcast: podcast))
        post show_stat_connections_path(show), params: { provider: "spotify", show_link: spotify_link }
        expect(podcast.stat_connections.sole.user).to eq(user)
      end
    end

    it "lets nobody but the owner connect a claimed podcast, or replace the owner's connection" do
      owner = create(:user)
      owner_show = create(:show, user: owner, podcast: podcast, verified_at: Time.current)
      podcast.update!(claimed_at: Time.current)
      owned = create(:stat_connection, podcast: podcast, user: owner, show: owner_show)

      post show_stat_connections_path(show), params: { provider: "spotify", show_link: spotify_link }
      expect(flash[:alert]).to eq(StatConnectionsController::CLAIMED_ELSEWHERE)
      expect { delete show_stat_connection_path(show, owned) }.not_to change(StatConnection, :count)
      expect(response).to have_http_status(:not_found)

      get show_stats_path(show)
      expect(response.body).to include("Another account owns this show")
      expect(response.body).not_to include("I&#39;ve invited Midrolo")
    end

    # L10: a draft workspace saw another account's pending connection: its Spotify show, its error, and buttons that 404.
    it "shows a draft workspace only its own connections, and the owner every connection on the podcast" do
      stranger = create(:user)
      theirs = create(:stat_connection, podcast: podcast, user: stranger, show: create(:show, user: stranger, podcast: podcast),
                                        external_id: "0StrangersShow0000000", last_error: "Spotify says the stranger's invite is missing.")

      get show_stats_path(show)
      expect(response.body).not_to include("0StrangersShow0000000", "the stranger&#39;s invite is missing",
                                           check_show_stat_connection_path(show, theirs))
      expect(response.body).to include('id="show_link_spotify"')

      claim!
      get show_stats_path(show)
      expect(response.body).to include("0StrangersShow0000000", check_show_stat_connection_path(show, theirs))
    end

    it "lets a draft user set up an invite, which waits for the claim" do
      expect { post show_stat_connections_path(show), params: { provider: "apple", show_link: "id1234567890" } }
        .to change(StatConnection, :count).by(1)
      expect(flash[:notice]).to include("Claim the show")
    end

    describe "a connection" do
      before { claim! }

      let!(:connection) { create(:stat_connection, podcast: podcast, show: show, user: user, status: "active", activated_at: 1.day.ago, last_synced_at: 1.hour.ago) }

      it "shows what it read and checks again on request" do
        Stats::Record.call(connection, spotify_result)
        get show_stats_path(show)
        expect(response.body).to include("Connected").and include("Streams, 30 days").and include("2,400")
        expect(response.body).to include("On your page").and include("Key numbers").and include("with Spotify for Creators")

        expect { post check_show_stat_connection_path(show, connection) }.to have_enqueued_job(Stats::SyncJob).with(connection.id)
        expect(response).to redirect_to(show_stats_path(show, anchor: "spotify"))
      end

      it "says when a check will run while Midrolo's limits make it wait" do
        travel_to(Time.utc(2026, 10, 30, 14, 0, 10)) do
          create(:service_session, platform: "spotify").update_columns(next_run_at: 10.minutes.from_now)
          expect { post check_show_stat_connection_path(show, connection) }.to have_enqueued_job(Stats::SyncJob)
          expect(flash[:notice]).to eq("Checking soon, around 14:10 UTC. Refresh then to see what we found.")
        end
      end

      it "says it checks now when the limits allow a run now" do
        create(:service_session, platform: "spotify")
        post check_show_stat_connection_path(show, connection)
        expect(flash[:notice]).to eq("Checking now. Refresh in a minute to see what we found.")
      end

      it "disconnects: the connection and its numbers go" do
        Stats::Record.call(connection, spotify_result)
        delete show_stat_connection_path(show, connection)

        expect(StatConnection.exists?(connection.id)).to be(false)
        expect(podcast.stat_readings.where(source: "spotify")).to be_empty
        expect(flash[:notice]).to include("remove stats@midrolo.com from your team in Spotify for Creators")
      end

      it "explains a mismatch in plain words" do
        connection.update!(status: "mismatch", last_error: "The Spotify show at that link isn't The Founder's Ledger. Check the link you pasted.")
        get show_stats_path(show)
        expect(response.body).to include("Doesn&#39;t match").and include("at that link isn&#39;t")
      end
    end

    describe "numbers provided by the show" do
      it "saves the owner's downloads per episode as a provided reading" do
        claim!
        patch provided_show_stats_path(show), params: { downloads_per_episode: "4,200" }

        expect(show.reload.downloads_per_episode).to eq(4_200)
        expect(podcast.stat_readings.sole).to have_attributes(source: "provided", trust: "provided", value: 4_200)
        expect(podcast.reload).to have_attributes(downloads_per_episode: 4_200, downloads_trust: "provided")
        follow_redirect!
        expect(response.body).to include("Provided by the show")

        patch provided_show_stats_path(show), params: { downloads_per_episode: "" }
        expect(podcast.stat_readings).to be_empty
      end

      it "keeps a draft's number in the workspace only" do
        patch provided_show_stats_path(show), params: { downloads_per_episode: "900" }
        expect(show.reload.downloads_per_episode).to eq(900)
        expect(podcast.stat_readings).to be_empty
        expect(flash[:notice]).to include("Claim the show")
      end

      it "refuses what isn't a whole number" do
        claim!
        patch provided_show_stats_path(show), params: { downloads_per_episode: "lots" }
        expect(flash[:alert]).to include("whole number")
        expect(podcast.stat_readings).to be_empty
      end
    end

    it "turns the owner's typed downloads on the details form into the provided reading" do
      claim!
      patch show_path(show), params: { show: { downloads_per_episode: 3_300, country: "US" } }
      expect(podcast.stat_readings.sole).to have_attributes(source: "provided", value: 3_300)
    end

    it "throttles invites", :rate_limits do
      claim!
      11.times { post show_stat_connections_path(show), params: { provider: "spotify", show_link: spotify_link } }
      expect(response).to have_http_status(:too_many_requests)
    end
  end
end
