require "rails_helper"

RSpec.describe "Account" do
  let(:user) { create(:user, name: "Ada Lovelace") }

  def with_judge_code(code)
    original = ENV["JUDGE_CODE"]
    ENV["JUDGE_CODE"] = code
    yield
  ensure
    ENV["JUDGE_CODE"] = original
  end

  it "requires sign-in" do
    get "/account"
    expect(response).to redirect_to("/users/sign_in")
  end

  it "renders plan, usage, judge code, billing and delete sections" do
    sign_in user
    get "/account"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Free", "Usage", "Judge code", "Billing", "Delete account", "Sign out", user.email, "AL")
  end

  it "renders the avatar when there is one" do
    sign_in create(:user, avatar_url: "https://example.com/a.png")
    get "/account"
    expect(response.body).to include("https://example.com/a.png")
  end

  describe "POST /account/judge_code" do
    before { sign_in user }

    it "grants judge access for the right code" do
      with_judge_code("sesame") { post "/account/judge_code", params: { code: "sesame" } }

      expect(user.reload.judge).to be true
      expect(response).to redirect_to("/account")
      expect(flash[:notice]).to eq("Judge access unlocked — enjoy full Pro features.")
    end

    it "rejects a wrong code" do
      with_judge_code("sesame") { post "/account/judge_code", params: { code: "nope" } }

      expect(user.reload.judge).to be false
      expect(flash[:alert]).to eq("That code didn't work.")
    end

    it "never matches when the configured code is blank" do
      with_judge_code("") { post "/account/judge_code", params: { code: "" } }
      expect(user.reload.judge).to be false

      with_judge_code(nil) { post "/account/judge_code", params: {} }
      expect(user.reload.judge).to be false
      expect(flash[:alert]).to eq("That code didn't work.")
    end
  end

  describe "DELETE /account" do
    it "destroys the user and signs out" do
      sign_in user

      expect { delete "/account" }.to change(User, :count).by(-1)

      expect(response).to redirect_to("/")
      get "/account"
      expect(response).to redirect_to("/users/sign_in")
    end
  end
end
