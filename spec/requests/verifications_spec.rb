require "rails_helper"

RSpec.describe "Verifications" do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:show) { create(:show, user: user, title: "The Founder's Ledger", owner_email: "jane@example.com") }

  def last_code = ActionMailer::Base.deliveries.last.text_part.body.to_s[/\b\d{6}\b/]

  def request_code
    perform_enqueued_jobs { post show_verification_path(show), params: { kind: "email" } }
  end

  it "requires sign in" do
    get new_show_verification_path(show)
    expect(response).to redirect_to("/users/sign_in")
  end

  context "when signed in" do
    before { sign_in user }

    it "404s for another user's show" do
      other = create(:show, owner_email: "x@example.com")
      [ -> { get new_show_verification_path(other) }, -> { get show_verification_path(other) },
        -> { post show_verification_path(other), params: { kind: "email" } },
        -> { patch show_verification_path(other), params: { code: "123456" } } ].each do |request|
        sign_in user # a 404 doesn't keep the test sign-in for the next request
        request.call
        expect(response).to have_http_status(:not_found)
      end
      expect(ShowVerification.count).to eq(0)
    end

    it "offers both methods and shows the owner address only masked" do
      get new_show_verification_path(show)

      expect(response.body).to include("j***@example.com", "Email me a code", "Get my feed token")
      expect(response.body).not_to include("jane@example.com")
    end

    it "emails a code to the feed's owner address and shows the masked address" do
      request_code

      expect(response).to redirect_to(show_verification_path(show))
      expect(ActionMailer::Base.deliveries.last.to).to eq([ "jane@example.com" ])
      follow_redirect!
      expect(response.body).to include("We sent a 6-digit code to j***@example.com")
      expect(response.body).not_to include("jane@example.com")
    end

    it "verifies the show with the right code and opens the kit editor" do
      request_code
      patch show_verification_path(show), params: { code: last_code }

      expect(response).to redirect_to(edit_show_media_kit_path(show))
      expect(flash[:notice]).to eq("You're verified. Publish your media kit when it's ready.")
      expect(show.reload.verified_at).to be_present
      expect(show.podcast.reload.claimed_at).to be_present
    end

    it "counts down the tries, then locks after 5 wrong codes and asks for a new one" do
      request_code
      code = last_code
      wrong = code == "000000" ? "111111" : "000000"

      patch show_verification_path(show), params: { code: wrong }
      expect(flash[:alert]).to eq("That code didn't match. You have 4 tries left.")
      4.times { patch show_verification_path(show), params: { code: wrong } }
      expect(flash[:alert]).to eq("Too many tries. Request a new code to try again.")

      patch show_verification_path(show), params: { code: code }
      expect(show.reload).not_to be_verified
      follow_redirect!
      expect(response.body).to include(ShowVerification::LOCKED_MESSAGE, "Send a new code") # the same copy as the flash
      expect(response.body).not_to include('name="code"')
    end

    it "throttles resends with a friendly wait" do
      freeze_time
      request_code
      travel 15.seconds
      post show_verification_path(show), params: { kind: "email" }

      expect(response).to redirect_to(show_verification_path(show))
      expect(flash[:alert]).to eq("We just sent a code. You can request another in 45 seconds.")
      expect(ShowVerification.count).to eq(1)
    end

    it "says when another account just sent a code to the same address, without blaming this user" do
      freeze_time
      other_user = create(:user)
      copy = create(:show, user: other_user, title: show.title, feed_url: show.feed_url, owner_email: "jane@example.com")
      sign_in other_user
      perform_enqueued_jobs { post show_verification_path(copy), params: { kind: "email" } }
      travel 15.seconds

      sign_in user
      post show_verification_path(show), params: { kind: "email" }
      expect(flash[:alert]).to eq("A code just went to this address. You can request another in 45 seconds.")
      expect(show.verifications.count).to eq(0)
      expect(ActionMailer::Base.deliveries.count { |mail| mail.to == [ "jane@example.com" ] }).to eq(1)
    end

    it "caps codes at 5 a day and points to the feed token" do
      5.times do
        request_code
        travel 61.seconds
      end
      post show_verification_path(show), params: { kind: "email" }

      expect(flash[:alert]).to start_with("You've requested 5 codes today. You can request another in about 24 hours")
      expect(flash[:alert]).to end_with("or verify with a feed token instead.")
    end

    it "keeps the code out of the logs" do
      io = StringIO.new
      log = ActiveSupport::Logger.new(io, level: :info)
      Rails.logger.broadcast_to(log)
      begin
        request_code
        code = last_code
        patch show_verification_path(show), params: { code: code }
      ensure
        Rails.logger.stop_broadcasting_to(log)
      end

      expect(io.string).to include("VerificationsController#update")
      expect(io.string).not_to include(code)
      expect(show.reload).to be_verified
    end

    context "when the feed lists no owner email" do
      before { show.podcast.update!(owner_email: nil) }

      it "offers only the feed token" do
        get new_show_verification_path(show)

        expect(response.body).to include("Your feed doesn't list an owner email", "Get my feed token")
        expect(response.body).not_to include("Email me a code")
      end

      it "refuses to send a code" do
        post show_verification_path(show), params: { kind: "email" }

        expect(response).to redirect_to(new_show_verification_path(show))
        expect(flash[:alert]).to include("doesn't list an owner email")
        expect(ShowVerification.count).to eq(0)
      end
    end

    describe "the feed token" do
      before { allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ]) }

      def feed_with(text)
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <rss version="2.0"><channel><title>The Founder's Ledger</title><description>#{text}</description>
            <item><title>Ep 1</title><pubDate>Mon, 12 Oct 2026 09:00:00 -0000</pubDate><guid>f-1</guid></item>
          </channel></rss>
        XML
      end

      it "gives copy-paste instructions with the token and a copy button" do
        post show_verification_path(show), params: { kind: "feed_token" }
        token = ShowVerification.last.token
        follow_redirect!

        expect(response.body).to include("midrolo-verify=#{token}", "data-controller=\"clipboard\"", "a few minutes")
      end

      it "verifies the show once the token is in the feed" do
        post show_verification_path(show), params: { kind: "feed_token" }
        stub_request(:get, show.feed_url).to_return(status: 200, body: feed_with("About us. midrolo-verify=#{ShowVerification.last.token}"))
        patch show_verification_path(show)

        expect(response).to redirect_to(edit_show_media_kit_path(show))
        expect(show.reload).to be_verified
      end

      it "says when the token isn't in the feed yet" do
        post show_verification_path(show), params: { kind: "feed_token" }
        stub_request(:get, show.feed_url).to_return(status: 200, body: feed_with("About us."))
        patch show_verification_path(show)

        expect(response).to redirect_to(show_verification_path(show))
        expect(flash[:alert]).to include("We couldn't find midrolo-verify=#{ShowVerification.last.token} in your feed yet",
                                         "a few minutes")
      end
    end

    it "says so, and verifies nothing, when another account already owns the podcast" do
      create(:show, podcast: show.podcast).verify!(via: "email")
      request_code
      patch show_verification_path(show), params: { code: last_code }

      expect(response).to redirect_to(show_path(show))
      expect(flash[:alert]).to eq(Show::AlreadyClaimed::MESSAGE)
      expect(show.reload).not_to be_verified
    end

    it "sends no code and issues no token for a show that is already verified" do
      show.verify!(via: "admin")

      %w[email feed_token].each do |kind|
        expect { post show_verification_path(show), params: { kind: kind } }.not_to have_enqueued_mail
        expect(response).to redirect_to(edit_show_media_kit_path(show))
        expect(flash[:notice]).to eq("You've already verified this show, so there's nothing to send.")
      end
      expect(ShowVerification.count).to eq(0)
    end

    it "shows a verified show's status instead of the forms" do
      show.verify!(via: "admin")
      get new_show_verification_path(show)

      expect(response.body).to include("You've verified that you own this show")
      expect(response.body).not_to include("Email me a code")
    end
  end
end
