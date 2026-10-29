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
    expect(response.body).not_to include("dev sign in")
  end

  describe "the dev sign in card (R101)" do
    def page = Nokogiri::HTML(response.body)

    it "posts a name and email straight to the developer callback, with a CSRF token, when the dev strategy is on" do
      allow(AuthConfig).to receive(:developer_strategy?).and_return(true)
      ActionController::Base.allow_forgery_protection = true

      get "/users/sign_in"

      card = page.at_css("[data-dev-sign-in]")
      expect(card.text.squish).to include("Dev sign in")
      form = card.at_css("form")
      expect(form["action"]).to eq("/users/auth/developer/callback")
      expect(form["method"]).to eq("post")
      expect(form["data-turbo"]).to eq("false")
      expect(form.css("input[name='name'], input[name='email']").size).to eq(2)
      expect(form.at_css("input[name='authenticity_token']")["value"]).to be_present
      # OmniAuth's own unstyled form (the request phase) is never linked, and Google isn't offered without its keys.
      expect(page.css("[action='/users/auth/developer'], [href='/users/auth/developer']")).to be_empty
      expect(response.body).not_to include("Continue with Google")
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    it "isn't there without the dev strategy: in production, with Google keys, and in test" do
      expect(AuthConfig.developer_strategy?(env: "production", client_id: nil)).to be(false)
      expect(AuthConfig.developer_strategy?(env: "development", client_id: "google-client-id")).to be(false)
      expect(AuthConfig.developer_strategy?(env: "development", client_id: "")).to be(true)

      get "/users/sign_in"
      expect(page.at_css("[data-dev-sign-in]")).to be_nil
      expect(response.body).not_to include("/users/auth/developer")
    end

    it "has no developer callback to post to when the strategy isn't configured: a 404, and nobody signed in" do
      OmniAuth.config.test_mode = false
      expect do
        post ApplicationHelper::DEV_SIGN_IN_PATH, params: { name: "Mallory", email: "mallory@example.com" }
      end.not_to change(User, :count)

      expect(response).to have_http_status(:not_found)
      get "/shows"
      expect(response).to redirect_to("/users/sign_in")
    ensure
      OmniAuth.config.test_mode = true
    end

    it "sends what OmniAuth's developer strategy reads: its callback takes name and email as the auth hash" do
      auth = nil
      app = lambda do |env|
        auth = env["omniauth.auth"]
        [ 200, {}, [ "" ] ]
      end
      # Mounted under Devise's prefix, as config/initializers/devise.rb mounts it in development.
      strategy = OmniAuth::Strategies::Developer.new(app, **AuthConfig::DEVELOPER_OPTIONS, path_prefix: "/users/auth")
      env = Rack::MockRequest.env_for(ApplicationHelper::DEV_SIGN_IN_PATH, method: "POST",
                                                                         params: { name: "Ada Lovelace", email: "ada@example.com" })
      env["rack.session"] = {}

      OmniAuth.config.test_mode = false
      strategy.call(env)

      expect(auth.uid).to eq("ada@example.com")
      expect(auth.info.to_h).to include("name" => "Ada Lovelace", "email" => "ada@example.com")
    ensure
      OmniAuth.config.test_mode = true
    end
  end

  it "signs in with Google and lands a new account on the podcaster or brand choice, then on /shows as a podcaster" do
    get "/users/auth/google_oauth2/callback"

    expect(response).to redirect_to("/welcome")
    expect(User.find_by(email: "ada@example.com")).to be_present
    patch "/side", params: { role: "podcaster" }
    expect(response).to redirect_to("/shows")
    follow_redirect! # a user with no shows is sent on to the add-a-show page
    expect(response).to redirect_to("/shows/new")
    follow_redirect!
    expect(response).to have_http_status(:ok)
  end

  it "goes back to the page that asked for sign in" do
    get "/pipeline"
    expect(response).to redirect_to("/users/sign_in")

    get "/users/auth/google_oauth2/callback"
    expect(response).to redirect_to("/pipeline")
  end

  it "lands someone who last worked as a brand on the brand workspace" do
    get "/users/auth/google_oauth2/callback"
    User.find_by!(email: "ada@example.com").update!(last_role: "brand")
    delete "/users/sign_out"

    get "/users/auth/google_oauth2/callback"
    expect(response).to redirect_to(ApplicationController::BRAND_HOME)
  end

  it "lands on the sign-in page with a notice when Google fails" do
    OmniAuth.config.mock_auth[:google_oauth2] = :access_denied
    OmniAuth.config.logger = Logger.new(nil)

    get "/users/auth/google_oauth2/callback"

    expect(response).to redirect_to("/users/sign_in")
  end

  it "rejects GET on the OAuth request phase (CSRF protection)" do
    expect(OmniAuth.config.allowed_request_methods).to eq([ :post ])

    OmniAuth.config.test_mode = false
    get "/users/auth/google_oauth2"

    expect(response).not_to redirect_to(%r{accounts\.google\.com})
  ensure
    OmniAuth.config.test_mode = true
  end

  it "does not 500 when the email belongs to a different user" do
    create(:user, email: "ADA@example.com")

    get "/users/auth/google_oauth2/callback"

    expect(response).to redirect_to("/users/sign_in")
    expect(flash[:alert]).to eq("We couldn't sign you in with that Google account. Please contact support.")
  end

  describe "the samples owner (R78)" do
    let!(:owner) { User.create!(email: User::SAMPLES_EMAIL) }

    it "can't be signed into with Google, even by the same email" do
      OmniAuth.config.mock_auth[:google_oauth2] = mock_google_auth(email: User::SAMPLES_EMAIL)

      get "/users/auth/google_oauth2/callback"

      expect(response).to redirect_to("/users/sign_in")
      get "/shows"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "gets no session even when one is forced on it" do
      sign_in owner
      get "/shows"

      expect(response).to redirect_to("/users/sign_in")
    end
  end

  it "shows Sign out in the signed-in app layout" do
    sign_in create(:user)
    get "/shows/new"

    expect(response.body).to include("Sign out", 'action="/users/sign_out"')
    expect(response.body).to include('name="_method" value="delete"')
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
