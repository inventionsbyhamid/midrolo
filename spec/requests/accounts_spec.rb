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

  describe "plan and usage" do
    def card(title)
      Nokogiri::HTML(response.body).css(".card").find { |node| node.at_css("h2")&.text&.squish == title }
    end

    let(:show) { create(:show, user: user) }

    it "shows the free plan and this month's usage" do
      create(:report, show: show, kind: "snapshot", status: "done")
      sign_in user
      get "/account"

      expect(card("Plan").text.squish).to include("Free", "You're on the Free plan.")
      expect(card("Plan").at_css("a[href='#{pricing_path}']").text).to eq("See plans")
      expect(card("Usage").css("li").map { |li| li.text.squish })
        .to eq([ "Full reports: not on the Free plan", "Snapshots: 1 of 1 used this month", "Pitches: not on the Free plan" ])
    end

    it "shows a subscriber's plan and this billing period's done work only" do
      create(:subscription, user: user, plan: "creator", current_period_start: 3.days.ago)
      create(:report, show: show, kind: "agent", status: "done", spend_bucket: "paid", created_at: 1.day.ago)
      create(:report, show: show, kind: "agent", status: "done", spend_bucket: "paid", created_at: 5.days.ago)
      create(:report, show: show, kind: "agent", status: "failed", spend_bucket: "paid")
      sign_in user
      get "/account"

      expect(card("Plan").text.squish).to include("Creator", "You're on the Creator plan.")
      expect(card("Usage").css("li").map { |li| li.text.squish })
        .to eq([ "Full reports: 1 of 4 used this billing period", "Snapshots: 0 of 4 used this billing period",
                 "Pitches: 0 of 40 used this billing period" ])
    end

    it "counts work in progress apart from done work, as the upgrade prompt does" do
      create(:subscription, user: user, plan: "creator")
      create(:report, show: show, kind: "agent", status: "done", spend_bucket: "paid")
      create(:report, show: create(:show, user: user), kind: "agent", status: "running", started_at: 1.minute.ago)
      sign_in user
      get "/account"

      expect(card("Usage").css("li").first.text.squish).to eq("Full reports: 1 of 4 used this billing period, 1 in progress")
    end

    it "gives the sprint's length from plans.yml" do
      create(:subscription, user: user, plan: "sprint", current_period_end: 29.days.from_now)
      allow(Entitlements).to receive(:limits).and_wrap_original do |original, key|
        key.to_sym == :sprint ? original.call(key).merge(duration_days: 14) : original.call(key)
      end
      sign_in user
      get "/account"

      expect(card("Plan").text.squish).to include("You're on the Sponsor Sprint: Pro features for 14 days.")
    end

    it "shows judge access with its reports in total and unlimited pitches, never a huge number" do
      user.update!(judge: true)
      create(:report, show: show, kind: "agent", status: "done", spend_bucket: "judge", created_at: 2.months.ago)
      sign_in user
      get "/account"

      expect(card("Plan").text.squish)
        .to include("Judge access", "Judge access is on: Pro features with 3 full reports and unlimited pitches.")
      expect(card("Usage").css("li").map { |li| li.text.squish })
        .to eq([ "Full reports: 1 of 3 used", "Snapshots: 0 of 12 used this month", "Unlimited pitches" ])
      expect(response.body).not_to include("Infinity", "∞")
    end

    it "shows the promo" do
      AppSettings.set(:promo_pro_until, 1.week.from_now.to_date.to_s)
      sign_in user
      get "/account"

      expect(card("Plan").text.squish).to include("Hackathon promo", "Free Pro access during the Qloo hackathon judging")
      expect(card("Usage").css("li").first.text.squish).to eq("Full reports: 0 of 1 used")
    end
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

    it "removes the user's shows" do
      sign_in user
      create(:show, user: user)
      other = create(:show)

      expect { delete "/account" }.to change(Show, :count).by(-1)
      expect(Show.exists?(other.id)).to be true
    end
  end
end
