require "rails_helper"

RSpec.describe "Claims" do
  include ActiveJob::TestHelper

  let(:user) { create(:user, email: "jane@example.com") }
  let(:podcast) { create(:podcast, :active, title: "The Founder's Ledger", feed_url: "https://feeds.example.com/ledger.xml") }

  describe "signed out" do
    before { OmniAuth.config.test_mode = true }
    after { OmniAuth.config.mock_auth[:google_oauth2] = nil }

    it "sends you to sign in, then back to the claim page" do
      get new_podcast_claim_path(podcast)
      expect(response).to redirect_to("/users/sign_in")

      OmniAuth.config.mock_auth[:google_oauth2] = mock_google_auth(email: "jane@example.com")
      get "/users/auth/google_oauth2/callback"
      expect(response).to redirect_to(new_podcast_claim_path(podcast))
    end

    it "needs sign in to claim or ask for access" do
      post podcast_claim_path(podcast)
      expect(response).to redirect_to("/users/sign_in")
      post podcast_claim_access_path(podcast)
      expect(response).to redirect_to("/users/sign_in")
      expect(Show.count).to eq(0)
    end
  end

  context "when signed in" do
    before { sign_in user }

    it "404s for an unknown or removed podcast" do
      get new_podcast_claim_path("no-such-show")
      expect(response).to have_http_status(:not_found)

      sign_in user
      podcast.update!(status: "removed")
      post podcast_claim_path(podcast)
      expect(response).to have_http_status(:not_found)
    end

    it "explains claiming, with the count of brands waiting, and never indexes the page" do
      create(:conversation, podcast: podcast, status: "waiting_for_claim")
      get new_podcast_claim_path(podcast)

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Robots-Tag"]).to include("noindex")
      expect(response.body).to include("Claim this show", "1 brand asked about sponsoring this show", "jane@example.com",
                                       podcast_claim_path(podcast))
    end

    it "claims at once when the feed's owner email is the address you signed in with" do
      stub_claim_feed(podcast.feed_url, owner_email: "Jane@Example.com")

      expect { post podcast_claim_path(podcast) }.to have_enqueued_job(Catalog::IngestPodcastJob).with(podcast.id)

      show = user.shows.sole
      expect(response).to redirect_to(edit_show_media_kit_path(show))
      expect(flash[:notice]).to eq("The Founder's Ledger is yours. Set up your listing below.")
      expect(show).to be_verified
      expect(podcast.reload).to be_claimed
      expect(ShowVerification.count).to eq(0)
    end

    it "reads the owner email fresh, and with someone else's sends you to choose a code or a token" do
      podcast.update!(owner_email: "old@example.com")
      stub_claim_feed(podcast.feed_url, owner_email: "host@example.com")

      post podcast_claim_path(podcast)

      show = user.shows.sole
      expect(response).to redirect_to(new_show_verification_path(show))
      expect(show).not_to be_verified
      expect(podcast.reload.owner_email).to eq("host@example.com")
      follow_redirect!
      expect(response.body).to include("h***@example.com", "Email me a code", "Get my feed token")
      expect(response.body).not_to include("host@example.com")
    end

    it "goes straight to the feed token, with Spotify for Creators steps, when a Spotify feed lists no owner email" do
      podcast.update!(feed_url: "https://anchor.fm/s/abc123/podcast/rss")
      stub_claim_feed(podcast.feed_url)

      post podcast_claim_path(podcast)

      show = user.shows.sole
      token = ShowVerification.sole
      expect(token).to be_feed_token
      expect(response).to redirect_to(show_verification_path(show))
      follow_redirect!
      expect(response.body).to include("midrolo-verify=#{token.token}", "Spotify for Creators", "Settings",
                                       %(&lt;podcast:txt purpose="verify"&gt;midrolo-verify=#{token.token}))
    end

    it "explains how to show the owner email on Spotify, and checks the feed again" do
      podcast.update!(feed_url: "https://anchor.fm/s/abc123/podcast/rss")
      stub_claim_feed(podcast.feed_url)
      post podcast_claim_path(podcast)
      show = user.shows.sole

      get new_show_verification_path(show)
      expect(response.body).to include("Your feed doesn't list an owner email", "Availability", "Add email to RSS feed",
                                       "Check my feed again")

      stub_claim_feed(podcast.feed_url, owner_email: "host@example.com")
      post podcast_claim_path(podcast, recheck: 1)
      expect(response).to redirect_to(new_show_verification_path(show))
      expect(flash[:notice]).to eq(ClaimsController::EMAIL_FOUND)

      stub_claim_feed(podcast.feed_url, owner_email: "jane@example.com")
      post podcast_claim_path(podcast, recheck: 1)
      expect(response).to redirect_to(edit_show_media_kit_path(show))
      expect(show.reload).to be_verified
    end

    it "says so when the feed still has no owner email after a recheck" do
      stub_claim_feed(podcast.feed_url)
      post podcast_claim_path(podcast, recheck: 1)

      expect(flash[:alert]).to eq(ClaimsController::EMAIL_MISSING)
    end

    it "reuses your workspace, and keeps an unreadable feed's stored owner email" do
      podcast.update!(owner_email: "host@example.com")
      allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ])
      stub_request(:get, podcast.feed_url).to_return(status: 500)
      existing = create(:show, user: user, podcast: podcast)

      2.times { post podcast_claim_path(podcast) }

      expect(user.shows.sole).to eq(existing)
      expect(podcast.reload.owner_email).to eq("host@example.com")
      expect(response).to redirect_to(new_show_verification_path(existing))
    end

    it "is never blocked by the plan's show limit" do
      stub_plan(shows: 1)
      create(:show, user: user)
      stub_claim_feed(podcast.feed_url, owner_email: "jane@example.com")

      post podcast_claim_path(podcast)

      expect(user.shows.count).to eq(2)
      expect(user.shows.find_by(podcast: podcast)).to be_verified
    end

    it "sends you to your listing when the show is already yours" do
      show = create(:show, user: user, podcast: podcast)
      show.verify!(via: "admin")

      get new_podcast_claim_path(podcast)
      expect(response).to redirect_to(edit_show_media_kit_path(show))
      post podcast_claim_path(podcast)
      expect(response).to redirect_to(edit_show_media_kit_path(show))
    end

    describe "a show another account manages" do
      let(:owner) { create(:user, email: "owner@example.com", name: "Olive Owner") }

      before { create(:show, user: owner, podcast: podcast).verify!(via: "admin") }

      it "says so, offers to ask the owner, and never names them" do
        get new_podcast_claim_path(podcast)

        expect(response.body).to include("This show is managed by someone else", "Ask the owner for access")
        expect(response.body).not_to include("owner@example.com", "Olive Owner", "Claim this show")
      end

      it "makes no workspace when you try to claim it" do
        post podcast_claim_path(podcast)

        expect(response).to redirect_to(new_podcast_claim_path(podcast))
        expect(user.shows).to be_empty
        expect(podcast.owner_show.user).to eq(owner)
      end

      it "emails the owner once a week, with replies going to you" do
        allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

        perform_enqueued_jobs { post podcast_claim_access_path(podcast) }
        expect(flash[:notice]).to eq(ClaimsController::ACCESS_SENT)
        mail = ActionMailer::Base.deliveries.sole
        expect(mail.to).to eq([ "owner@example.com" ])
        expect(mail.reply_to).to eq([ "jane@example.com" ])
        expect(mail.subject).to eq("Test User asked for access to The Founder's Ledger on Midrolo")
        expect(mail.text_part.body.to_s).to include("jane@example.com", "We haven't shared your name or email with them")

        perform_enqueued_jobs { post podcast_claim_access_path(podcast) }
        expect(flash[:notice]).to eq(ClaimsController::ACCESS_ALREADY_SENT)
        expect(ActionMailer::Base.deliveries.size).to eq(1)
      end
    end

    it "sends the verification page's AlreadyClaimed to the claim page" do
      podcast.update!(owner_email: "jane+feed@example.com")
      show = create(:show, user: user, podcast: podcast)
      perform_enqueued_jobs { post show_verification_path(show), params: { kind: "email" } }
      create(:show, podcast: podcast).verify!(via: "email")
      code = ActionMailer::Base.deliveries.last.text_part.body.to_s[/\b\d{6}\b/]

      patch show_verification_path(show), params: { code: code }

      expect(response).to redirect_to(new_podcast_claim_path(podcast))
      expect(flash[:alert]).to eq(Show::AlreadyClaimed::MESSAGE)
    end
  end
end
