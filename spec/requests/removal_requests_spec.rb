require "rails_helper"

RSpec.describe "Remove this page" do
  let(:podcast) { create(:podcast, :indexable, :with_artwork, title: "Darknet Diaries", podcast_guid: "guid-darknet") }

  it "asks a visitor for an email and a reason, and keeps the request for an admin" do
    get new_podcast_removal_path(podcast)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Remove the page for Darknet Diaries", "Send the request")
    expect(response.headers["X-Robots-Tag"]).to eq("noindex")

    post podcast_removal_path(podcast), params: { removal_request: { email: "", reason: "Please." } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(RemovalRequestsController::EMAIL_NEEDED)

    post podcast_removal_path(podcast), params: { removal_request: { email: "host@example.com", reason: "I host it." } }
    expect(response).to redirect_to(podcast_path(podcast))
    expect(flash[:notice]).to eq(RemovalRequestsController::RECEIVED)
    expect(RemovalRequest.last).to have_attributes(podcast: podcast, email: "host@example.com", status: "pending")
    expect(podcast.reload).not_to be_removed
  end

  it "removes the page at once for its signed-in owner" do
    owner = create(:user, email: "jack@example.com")
    create(:show, user: owner, podcast: podcast).verify!(via: "admin")
    sign_in owner

    get new_podcast_removal_path(podcast)
    expect(response.body).to include("Remove the page now")

    post podcast_removal_path(podcast), params: { removal_request: { reason: "" } }
    expect(response).to redirect_to(podcasts_path)
    expect(flash[:notice]).to eq(RemovalRequestsController::REMOVED)
    expect(RemovalRequest.last).to have_attributes(status: "approved", email: "jack@example.com")
    expect(podcast.reload).to be_removed
    expect(Suppression.podcast?(guid: "guid-darknet")).to be(true)

    get podcast_path(podcast)
    expect(response).to have_http_status(:gone)
    get new_podcast_removal_path(podcast)
    expect(response).to have_http_status(:gone)
  end

  it "doesn't treat another user's workspace as ownership" do
    create(:show, podcast: podcast).verify!(via: "admin")
    sign_in create(:user)
    post podcast_removal_path(podcast), params: { removal_request: { email: "someone@example.com" } }
    expect(podcast.reload).not_to be_removed
    expect(RemovalRequest.last.status).to eq("pending")
  end

  it "throttles requests", :rate_limits do
    5.times { post podcast_removal_path(podcast), params: { removal_request: { email: "a@example.com" } } }
    post podcast_removal_path(podcast), params: { removal_request: { email: "a@example.com" } }
    expect(response).to have_http_status(:too_many_requests)
  end

  describe "admin review" do
    let(:admin) { create(:user, admin: true) }
    let!(:request_row) { create(:removal_request, podcast: podcast, email: "host@example.com") }

    it "lists pending requests and approves one, which removes the page" do
      sign_in admin
      get admin_removal_requests_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Darknet Diaries", "host@example.com")

      patch admin_removal_request_path(request_row), params: { decision: "approved" }
      expect(response).to redirect_to(admin_removal_requests_path)
      expect(request_row.reload.status).to eq("approved")
      expect(podcast.reload).to be_removed
    end

    it "rejects one, leaving the page up" do
      sign_in admin
      patch admin_removal_request_path(request_row), params: { decision: "rejected" }
      expect(request_row.reload.status).to eq("rejected")
      expect(podcast.reload).not_to be_removed
    end

    it "is a 404 for anyone else" do
      sign_in create(:user)
      get admin_removal_requests_path
      expect(response).to have_http_status(:not_found)
      patch admin_removal_request_path(request_row), params: { decision: "approved" }
      expect(response).to have_http_status(:not_found)
      expect(podcast.reload).not_to be_removed
    end
  end
end
