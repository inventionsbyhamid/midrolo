require "rails_helper"

# Request a spot and the inboxes (build spec L7): asking on claimed and unclaimed shows, the pages for both sides,
# answers, report and block, and who may see what (a third party gets a 404 everywhere).
RSpec.describe "Conversations" do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, name: "Maya Brandt", email: "maya@example.com") }
  let(:podcast) { claimed_podcast(owner: owner, title: "The Founder's Ledger") }
  let(:asker) { create(:user, name: "Sam Rivera", email: "sam@fieldnote.example") }
  let(:brand) { create(:brand, name: "Fieldnote Coffee", domain: "fieldnote.example") }
  let!(:membership) { brand_member_for(asker, brand: brand) }
  let(:month) { Date.current.next_month.strftime("%Y-%m") }

  def ask(target = podcast, **fields)
    perform_enqueued_jobs do
      post conversations_path, params: { podcast: target.slug,
                                         spot_request: { format: "midroll", months: [ "", month ], budget: "500",
                                                         body: "We'd love a midroll." }.merge(fields) }
    end
  end

  before { ActionMailer::Base.deliveries.clear }

  it "requires sign in, and comes back to the form after it" do
    get new_conversation_path(podcast: podcast.slug)
    expect(response).to redirect_to("/users/sign_in")

    get inbox_path
    expect(response).to redirect_to("/users/sign_in")
  end

  describe "asking" do
    before { sign_in asker }

    it "shows the form, with the day's allowance and the unverified note" do
      get new_conversation_path(podcast: podcast.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Request a spot", "You can send 3 more requests today", "Unverified brand label",
                                       "Send request", "Midroll")
      expect(response.body).not_to include("hasn't claimed")
    end

    it "opens a request on a claimed show, emails its owner and lands on the thread" do
      ask

      conversation = Conversation.last
      expect(response).to redirect_to(conversation_path(conversation))
      expect(flash[:notice]).to eq(ConversationsController::SENT)
      expect(conversation).to have_attributes(status: "open", months: [ month ], budget_cents: 50_000, brand: brand)
      expect(ActionMailer::Base.deliveries.map(&:to)).to eq([ [ "maya@example.com" ] ])

      follow_redirect!
      expect(response.body).to include("The Founder&#39;s Ledger", "We&#39;d love a midroll.", "Withdraw request")
    end

    it "holds a request on an unclaimed show, emails nobody and says so" do
      unclaimed = create(:podcast, title: "Night Owls", owner_email: "feed-owner@example.com")
      get new_conversation_path(podcast: unclaimed.slug)
      expect(response.body).to include("Night Owls hasn't claimed its Midrolo page yet", "We never email shows")

      ask(unclaimed)

      expect(Conversation.last).to be_waiting_for_claim
      expect(flash[:notice]).to eq(ConversationsController::WAITING)
      expect(ActionMailer::Base.deliveries).to be_empty
      follow_redirect!
      expect(response.body).to include("Waiting for the show", "Add to your request")
    end

    it "sends a second ask to the request already running" do
      ask
      get new_conversation_path(podcast: podcast.slug)
      expect(response).to redirect_to(conversation_path(Conversation.last))

      ask
      expect(flash[:notice]).to eq(ConversationsController::ALREADY_ASKED)
      expect(Conversation.count).to eq(1)
    end

    it "shows the form again with the problem" do
      ask(body: "", budget: "a lot")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Message can&#39;t be blank")
      expect(Conversation.count).to eq(0)
    end

    it "stops an unverified member after 3 requests a day" do
      3.times { ask(create(:podcast)) }
      ask(create(:podcast))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("You&#39;ve sent 3 requests in the last 24 hours")
      expect(Conversation.count).to eq(3)
    end

    it "404s for a removed or unknown show" do
      ask(create(:podcast, status: "removed"))
      expect(response).to have_http_status(:not_found)

      sign_in asker # a 404 doesn't keep the test sign-in for the next request
      get new_conversation_path(podcast: "no-such-show")
      expect(response).to have_http_status(:not_found)
    end
  end

  it "sends someone without a brand to set one up, then back to the form" do
    sign_in create(:user)
    get new_conversation_path(podcast: podcast.slug)

    expect(response).to redirect_to(ApplicationController::BRAND_HOME)
    expect(flash[:notice]).to eq(ConversationsController::NEEDS_BRAND)
    expect(session["user_return_to"]).to eq(new_conversation_path(podcast: podcast.slug))
  end

  it "comes back to the form once the brand is set up" do
    sign_in create(:user)
    get new_conversation_path(podcast: podcast.slug)
    post brand_profile_path, params: { name: "Fieldnote Coffee", website: "fieldnote.example" }

    expect(response).to redirect_to(new_conversation_path(podcast: podcast.slug))
    follow_redirect!
    expect(response.body).to include("Send request")
  end

  it "sends the owner of the show to their inbox instead" do
    sign_in owner
    get new_conversation_path(podcast: podcast.slug)
    expect(response).to redirect_to(inbox_path)
  end

  describe "with a request" do
    let(:conversation) { start_request(podcast, membership, body: "We'd love a midroll.") }

    before do
      conversation
      ActionMailer::Base.deliveries.clear
    end

    it "lists it in the owner's inbox, the workspace's and the brand's, and marks it read when opened" do
      sign_in owner
      get inbox_path
      expect(response.body).to include("Fieldnote Coffee", "Unverified brand", "For The Founder&#39;s Ledger", "New:")

      get show_inbox_path(podcast.owner_show)
      expect(response.body).to include("Requests to The Founder&#39;s Ledger", "Fieldnote Coffee")

      get conversation_path(conversation)
      expect(response.body).to include("New request.", "Accept", "Decline", "Block Fieldnote Coffee",
                                       "Unverified brand: nobody has confirmed a work email at fieldnote.example")
      expect(conversation.reload.unread_for?(:podcaster)).to be(false)

      sign_in asker
      get brand_inbox_path
      expect(response.body).to include("The Founder&#39;s Ledger", "Open")
    end

    it "asks an unverified workspace to verify, with the brands waiting" do
      unclaimed = create(:podcast)
      start_request(unclaimed, brand_member_for)
      show = create(:show, user: owner, podcast: unclaimed)
      sign_in owner

      get show_inbox_path(show)
      expect(response.body).to include("Verify this show to read its requests", "1 brand asked about sponsoring it")

      get show_path(show)
      expect(response.body).to include("1 brand asked about sponsoring this show")
    end

    it "keeps a third party out of every page and action" do
      stranger = create(:user)
      [ -> { get conversation_path(conversation) },
        -> { get show_inbox_path(podcast.owner_show) },
        -> { patch accept_conversation_path(conversation) },
        -> { patch close_conversation_path(conversation) },
        -> { post report_conversation_path(conversation) },
        -> { post block_conversation_path(conversation) },
        -> { post conversation_messages_path(conversation), params: { message: { body: "Hi" } } } ].each do |request|
        sign_in stranger # a 404 doesn't keep the test sign-in for the next request
        request.call
        expect(response).to have_http_status(:not_found)
      end
      expect(conversation.reload).to have_attributes(status: "open", reported_at: nil)
      expect(conversation.messages.count).to eq(1)
    end

    # M1: new and create used to redirect an unverified colleague to this thread, which 404s for them.
    it "tells an unverified colleague the brand already asked, without the thread, its date or a second request" do
      colleague = brand_member_for(brand: brand)
      sign_in colleague.user

      get new_conversation_path(podcast: podcast.slug)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(Conversations::Start::COLLEAGUE_ASKED)
      expect(response.body).not_to include(conversation_path(conversation), "spot_request[body]")

      ask
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(Conversations::Start::COLLEAGUE_ASKED)
      expect(response.body).not_to include(conversation_path(conversation))
      expect(Conversation.count).to eq(1)
    end

    it "keeps an unverified member of the brand out, and lets a verified one in" do
      colleague = brand_member_for(brand: brand)
      sign_in colleague.user
      get conversation_path(conversation)
      expect(response).to have_http_status(:not_found)

      colleague.update!(verified_at: Time.current)
      sign_in colleague.user
      get conversation_path(conversation)
      expect(response).to have_http_status(:ok)
    end

    it "lets only the podcaster answer" do
      sign_in asker
      patch accept_conversation_path(conversation)
      expect(response).to have_http_status(:not_found)
      expect(conversation.reload).to be_open
    end

    it "accepts, and tells the asker" do
      sign_in owner
      perform_enqueued_jobs { patch accept_conversation_path(conversation) }

      expect(response).to redirect_to(conversation_path(conversation))
      expect(conversation.reload).to be_accepted
      expect(ActionMailer::Base.deliveries.map(&:subject)).to eq([ "The Founder's Ledger accepted your request" ])

      patch accept_conversation_path(conversation)
      expect(flash[:alert]).to eq("This request was already accepted.")
    end

    it "declines with a reason the brand sees, and asks for one when it's missing" do
      sign_in owner
      patch decline_conversation_path(conversation), params: { decline_reason: "" }
      expect(flash[:alert]).to eq("Give a short reason so the brand knows why.")
      expect(conversation.reload).to be_open

      patch decline_conversation_path(conversation), params: { decline_reason: "Booked through December." }
      expect(conversation.reload).to have_attributes(status: "declined", decline_reason: "Booked through December.")

      sign_in asker
      get conversation_path(conversation)
      expect(response.body).to include("Declined.", "Booked through December.", "This request was declined")
    end

    it "lets the brand withdraw" do
      sign_in asker
      patch close_conversation_path(conversation)

      expect(conversation.reload).to be_closed
      expect(flash[:notice]).to eq("Request withdrawn.")
    end

    it "reports once to the admins" do
      create(:user, admin: true, email: "ops@example.com")
      sign_in owner
      perform_enqueued_jobs { 2.times { post report_conversation_path(conversation) } }

      expect(conversation.reload.reported_at).to be_present
      expect(ActionMailer::Base.deliveries.map(&:to)).to eq([ [ "ops@example.com" ] ])
    end

    it "blocks and unblocks the brand" do
      sign_in owner
      post block_conversation_path(conversation)

      expect(conversation.reload).to be_closed
      expect(Block.exists?(podcast: podcast, brand: brand)).to be(true)
      follow_redirect!
      expect(response.body).to include("You blocked Fieldnote Coffee", "Unblock Fieldnote Coffee")

      sign_in asker
      ask
      expect(response.body).to include(Conversations::Start::BLOCKED.gsub("'", "&#39;"))

      sign_in owner
      delete block_conversation_path(conversation)
      expect(Block.count).to eq(0)
    end

    it "shows reported conversations on the admin dashboard" do
      conversation.report!
      admin = create(:user, admin: true)
      saved = ENV.values_at("ADMIN_USERNAME", "ADMIN_PASSWORD")
      ENV["ADMIN_USERNAME"] = "ops"
      ENV["ADMIN_PASSWORD"] = "secret"
      sign_in admin
      get admin_root_path, headers: { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("ops", "secret") }

      expect(response.body).to include("Requests", "Reported", conversation.public_id, "Fieldnote Coffee")
    ensure
      ENV["ADMIN_USERNAME"], ENV["ADMIN_PASSWORD"] = saved
    end
  end

  it "says so when there's nothing yet" do
    sign_in create(:user)
    get inbox_path

    expect(response.body).to include("Nothing here yet", "Set up your brand")
  end

  it "throttles requests per user", :rate_limits do
    sign_in asker
    11.times { post conversations_path, params: { podcast: podcast.slug, spot_request: { body: "" } } }

    expect(response).to have_http_status(:too_many_requests)
  end
end
