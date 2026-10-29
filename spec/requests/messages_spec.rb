require "rails_helper"

# Replies in a thread, for both sides: a Turbo Stream appends the message and a fresh form; a closed thread says so.
RSpec.describe "Messages" do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, name: "Maya Brandt", email: "maya@example.com") }
  let(:podcast) { claimed_podcast(owner: owner) }
  let(:membership) { brand_member_for(create(:user, name: "Sam Rivera", email: "sam@fieldnote.example")) }
  let(:conversation) { start_request(podcast, membership) }

  def stream = { "Accept" => "text/vnd.turbo-stream.html" }

  before do
    conversation
    ActionMailer::Base.deliveries.clear
  end

  it "appends the podcaster's reply, records the first reply and emails the brand" do
    sign_in owner
    perform_enqueued_jobs do
      post conversation_messages_path(conversation), params: { message: { body: "Happy to talk.\nWhat's the product?" } },
                                                     headers: stream
    end

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    expect(response.body).to include("turbo-stream action=\"append\"", "Happy to talk.", "You")
    expect(conversation.reload.first_reply_at).to be_present
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([ [ "sam@fieldnote.example" ] ])

    sign_in membership.user
    get conversation_path(conversation)
    expect(response.body).to include("Maya, The Founder", "Happy to talk.")
  end

  it "keeps the box with the problem for an empty or closed thread" do
    sign_in owner
    post conversation_messages_path(conversation), params: { message: { body: " " } }, headers: stream
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("turbo-stream action=\"replace\"", Conversations::Reply::EMPTY)

    conversation.close!(by: :brand)
    post conversation_messages_path(conversation), params: { message: { body: "Hello?" } }
    expect(response).to redirect_to(conversation_path(conversation))
    expect(flash[:alert]).to eq(Conversations::Reply::CLOSED)
  end
end
