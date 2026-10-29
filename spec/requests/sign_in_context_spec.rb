require "rails_helper"

# UX review G-3: a signed-out action lands on sign in with what you were doing as the title, not Devise's red alert.
RSpec.describe "Sign in context" do
  let(:podcast) { create(:podcast, :active, title: "Shipping Soon") }

  def follow_to_sign_in(path)
    get path
    expect(response).to redirect_to(new_user_session_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
  end

  it "says which show you're claiming" do
    follow_to_sign_in(new_podcast_claim_path(podcast))
    expect(response.body).to include("Sign in to claim Shipping Soon")
    expect(response.body).not_to include(I18n.t("devise.failure.unauthenticated"))
  end

  it "says you're finding podcasts for your brand" do
    follow_to_sign_in("/brand")
    expect(response.body).to include("Sign in to find podcasts for your brand")
    expect(response.body).not_to include(I18n.t("devise.failure.unauthenticated"))
  end

  it "says which show you're requesting a spot on" do
    follow_to_sign_in(new_conversation_path(podcast: podcast.slug))
    expect(response.body).to include("Sign in to request a spot on Shipping Soon")
  end

  it "keeps the plain title with nowhere stored" do
    get new_user_session_path
    expect(response.body).to include("Sign in to #{APP_NAME}")
  end
end
