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

      expect(card("Plan").text.squish).to include("You're on the Sprint plan: Pro features for 14 days.")
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

  describe "billing (R66)" do
    def card(title)
      Nokogiri::HTML(response.body).css(".card").find { |node| node.at_css("h2")&.text&.squish == title }
    end

    def forms_to(path) = card("Billing").css("form[action='#{path}']")

    around { |example| travel_to(Time.zone.local(2026, 10, 25, 12)) { example.run } }

    it "offers the founding-member waitlist for every price in waitlist mode, with no checkout" do
      with_billing_env do
        sign_in user
        get "/account"
      end

      expect(forms_to("/waitlist_entries").map { |form| form.at_css("input[name=price_key]")["value"] })
        .to eq(%w[creator_monthly creator_yearly pro_monthly pro_yearly sprint])
      expect(forms_to("/waitlist_entries").map { |form| form.at_css("[type=submit]")["value"] }.uniq)
        .to eq([ "Join the founding member waitlist" ])
      expect(forms_to("/waitlist_entries").css("input[name=email]")).to be_empty # signed in: the account's email
      expect(forms_to("/checkouts")).to be_empty
      expect(card("Billing").text).to include("Creator", "$19/month", "$190/year", "Pro", "$49/month", "$490/year",
                                              "Sprint", "$49 once")
      expect(card("Billing").text).not_to include("Test mode")
    end

    it "also offers a judge a test checkout, with the test-card note" do
      user.update!(judge: true)
      with_billing_env do
        sign_in user
        get "/account"
      end

      expect(forms_to("/waitlist_entries").size).to eq(5)
      expect(forms_to("/checkouts").map { |form| form.at_css("[type=submit]").text.squish }.uniq)
        .to eq([ "Try checkout in test mode" ])
      expect(card("Billing").text).to include(BillingHelper::TEST_NOTE)
    end

    it "offers checkout to everyone in test mode" do
      with_billing_env("BILLING_MODE" => "test") do
        sign_in user
        get "/account"
      end

      expect(forms_to("/checkouts").map { |form| form.at_css("input[name=price_key]")["value"] })
        .to eq(%w[creator_monthly creator_yearly pro_monthly pro_yearly sprint])
      expect(forms_to("/waitlist_entries")).to be_empty
      expect(card("Billing").text).to include(BillingHelper::TEST_NOTE)
    end

    it "shows a subscriber the renewal date and Manage billing, in test and live modes" do
      create(:subscription, user: user, provider: "fake", provider_customer_id: "fake_cus_1",
                            current_period_end: Time.zone.local(2026, 11, 24, 12))
      with_billing_env("BILLING_MODE" => "test") do
        sign_in user
        get "/account"
      end

      expect(card("Plan").text.squish).to include("Renews on Nov 24, 2026.")
      expect(forms_to("/billing_portal").at_css("[type=submit]").text.squish).to eq("Manage billing")
      expect(forms_to("/checkouts")).to be_empty
    end

    it "shows Manage billing in any mode, the waitlist included, when there is a customer id (R73)" do
      create(:subscription, user: user, provider: "fake", provider_customer_id: "fake_cus_1")
      with_billing_env do
        sign_in user
        get "/account"
      end
      expect(forms_to("/billing_portal").at_css("[type=submit]").text.squish).to eq("Manage billing")

      other = create(:user)
      create(:subscription, user: other, provider: "fake", provider_customer_id: nil)
      with_billing_env("BILLING_MODE" => "test") do
        sign_in other
        get "/account"
      end
      expect(forms_to("/billing_portal")).to be_empty
    end

    it "says when a plan ends instead of renewing" do
      create(:subscription, user: user, status: "canceled", current_period_end: Time.zone.local(2026, 11, 2, 9))
      sign_in user
      get "/account"
      expect(card("Plan").text.squish).to include("Ends on Nov 2, 2026. It won't renew.")

      user.subscriptions.sole.update!(status: "active", cancel_at_period_end: true)
      get "/account"
      expect(card("Plan").text.squish).to include("Ends on Nov 2, 2026. It won't renew.")
    end

    it "gives a sprint's end and a failed payment's warning" do
      create(:subscription, user: user, plan: "sprint", current_period_end: Time.zone.local(2026, 11, 20, 12))
      sign_in user
      get "/account"
      expect(card("Plan").text.squish).to include("Your Sprint ends on Nov 20, 2026.")

      user.subscriptions.sole.update!(plan: "creator", price_key: "creator_monthly", status: "past_due")
      get "/account"
      expect(card("Plan").text.squish).to include("Your last payment failed. Update your card in Manage billing to keep your plan.")
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
      expect(flash[:notice]).to eq("Judge access unlocked. Enjoy full Pro features.")
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

    # The per-user limit (R83), which no spelling of the path gets around. spec/requests/rate_limits_spec.rb has the
    # per-IP one.
    it "takes 5 tries an hour, then answers with the friendly 429, the right code included", :rate_limits do
      with_judge_code("sesame") do
        5.times do |n|
          post [ "/account/judge_code", "/account/judge_code.html", "/account//judge_code" ][n % 3], params: { code: "nope" }
          expect(response).to redirect_to("/account")
        end
        post "/account/judge_code/", params: { code: "sesame" }
      end

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq("3600")
      expect(Nokogiri::HTML(response.body).at_css("h1").text).to eq("Too many requests")
      expect(user.reload.judge).to be false

      post "/account/judge_code", params: { code: "nope" }, headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
      expect(response).to have_http_status(:too_many_requests)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include('target="flash"', ThrottledResponse::MESSAGE)
    end

    it "counts each user's tries apart", :rate_limits do
      5.times { post "/account/judge_code", params: { code: "nope" } }
      sign_in create(:user)
      post "/account/judge_code", params: { code: "nope" }, env: { "REMOTE_ADDR" => "198.51.100.9" }
      expect(response).to redirect_to("/account")
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

    # R129: the privacy page promises deletion, whatever the account holds. Spend rows stay for the budget totals,
    # with no owner.
    it "deletes an account that holds every kind of record and keeps its spend rows ownerless" do
      show = create(:show, user: user)
      snapshot = create(:report, show: show, kind: "snapshot", status: "done")
      agent = create(:report, show: show, kind: "agent", status: "done", spend_bucket: "paid")
      create(:agent_step, report: agent)
      match = create(:sponsor_match, report: agent, status: "pitched")
      create(:sponsor_match, report: snapshot, status: "saved")
      pitch = Pitch.create!(sponsor_match: match, status: "done")
      Llm::Budget.record!(user: user, bucket: :paid, model: "claude-opus-5-5", tokens: { input: 1000 }, report: agent)
      Llm::Budget.record!(user: user, bucket: :paid, model: "claude-opus-5-5", tokens: { input: 500 }, pitch: pitch)
      create(:subscription, user: user, cancel_at_period_end: true)
      WaitlistEntry.join(email: user.email, price_key: "pro_monthly", user: user)
      verified = create(:show, user: user)
      ShowVerification.create!(show: verified, kind: "email", sent_to: "host@example.com", expires_at: 30.minutes.from_now)
      kit = create(:media_kit, :published, show: verified)
      kit.cover.attach(io: file_fixture("cover.png").open, filename: "cover.png")
      kit.host_photo.attach(io: file_fixture("host.jpg").open, filename: "host.jpg")
      others = create(:show)
      create(:report, show: others)
      spent_before = Llm::Budget.usage

      sign_in user
      perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { delete "/account" }

      expect(response).to redirect_to("/")
      expect(flash[:notice]).to eq("Your account and data were deleted.")
      expect(User.exists?(user.id)).to be false
      expect(Show.where(user_id: user.id)).to be_empty
      expect(Report.where(id: [ snapshot.id, agent.id ])).to be_empty
      expect(AgentStep.count).to eq(0)
      expect(SponsorMatch.count).to eq(0)
      expect(Pitch.count).to eq(0)
      expect(Subscription.count).to eq(0)
      expect(WaitlistEntry.count).to eq(0)
      expect(ShowVerification.count).to eq(0)
      expect(MediaKit.count).to eq(0)
      expect(ActiveStorage::Attachment.count).to eq(0)
      expect(ActiveStorage::Blob.count).to eq(0)
      expect(SpendEntry.count).to eq(2)
      expect(SpendEntry.pluck(:user_id, :report_id)).to all(eq([ nil, nil ]))
      expect(Llm::Budget.usage).to eq(spent_before)
      expect(Report.where(show: others).count).to eq(1)
    end
  end
end
