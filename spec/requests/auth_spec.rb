require "rails_helper"

RSpec.describe "Authentication" do
  before do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = mock_google_auth
  end

  after { OmniAuth.config.mock_auth[:google_oauth2] = nil }

  it "shows one Continue with Google button that posts without Turbo" do
    get "/users/sign_in"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Continue with Google", 'action="/users/auth/google_oauth2"', 'data-turbo="false"')
    expect(response.body).not_to include("dev sign-in")
  end

  it "signs in with Google and lands on /shows" do
    get "/users/auth/google_oauth2/callback"

    expect(response).to redirect_to("/shows")
    expect(User.find_by(email: "ada@example.com")).to be_present
    follow_redirect!
    expect(response).to have_http_status(:ok)
  end

  it "lands on the sign-in page with a notice when Google fails" do
    OmniAuth.config.mock_auth[:google_oauth2] = :access_denied
    OmniAuth.config.logger = Logger.new(nil)

    get "/users/auth/google_oauth2/callback"

    expect(response).to redirect_to("/users/sign_in")
  end

  it "redirects signed-out visitors from /shows to sign-in" do
    get "/shows"

    expect(response).to redirect_to("/users/sign_in")
  end

  it "signs out with DELETE" do
    sign_in create(:user)

    delete "/users/sign_out"

    expect(response).to redirect_to("/")
    get "/shows"
    expect(response).to redirect_to("/users/sign_in")
  end
end
