require "rails_helper"

RSpec.describe "Admin" do
  let(:admin) { create(:user, admin: true, email: "ops@example.com") }
  let(:basic_auth) { { "HTTP_AUTHORIZATION" => basic("ops-user", "correct horse") } }

  def basic(username, password) = ActionController::HttpAuthentication::Basic.encode_credentials(username, password)

  # ADMIN_USERNAME and ADMIN_PASSWORD for the block (nil unsets one), restored after.
  def with_admin_env(username: "ops-user", password: "correct horse")
    saved = ENV.values_at("ADMIN_USERNAME", "ADMIN_PASSWORD")
    { "ADMIN_USERNAME" => username, "ADMIN_PASSWORD" => password }.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    yield
  ensure
    { "ADMIN_USERNAME" => saved[0], "ADMIN_PASSWORD" => saved[1] }.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  around { |example| with_admin_env { example.run } }

  describe "access (R68)" do
    %w[/admin /admin/jobs].each do |path|
      describe path do
        it "opens for a signed-in admin with basic auth" do
          sign_in admin
          get path, headers: basic_auth
          expect(response).to have_http_status(:ok)
        end

        it "asks a signed-in admin for basic auth (401) without it, or with a wrong username or password" do
          sign_in admin
          get path
          expect(response).to have_http_status(:unauthorized)
          expect(response.headers["WWW-Authenticate"]).to start_with("Basic")

          get path, headers: { "HTTP_AUTHORIZATION" => basic("ops-user", "wrong") }
          expect(response).to have_http_status(:unauthorized)
          get path, headers: { "HTTP_AUTHORIZATION" => basic("someone", "correct horse") }
          expect(response).to have_http_status(:unauthorized)
        end

        it "is not found for a signed-in user who isn't an admin, even with basic auth" do
          sign_in create(:user)
          get path, headers: basic_auth
          expect(response).to have_http_status(:not_found)
          expect(response.headers["WWW-Authenticate"]).to be_nil
        end

        it "is not found when signed out, even with basic auth" do
          get path, headers: basic_auth
          expect(response).to have_http_status(:not_found)
        end

        it "is not found when ADMIN_USERNAME or ADMIN_PASSWORD is unset, whatever is sent" do
          sign_in admin
          with_admin_env(username: nil) do
            get path, headers: basic_auth
            expect(response).to have_http_status(:not_found)
          end
          with_admin_env(password: "") do
            get path, headers: { "HTTP_AUTHORIZATION" => basic("ops-user", "") }
            expect(response).to have_http_status(:not_found)
          end
        end
      end
    end
  end

  context "as a signed-in admin with basic auth" do
    let(:owner) { create(:user) }
    let(:show) { create(:show, user: owner, title: "Money Talks") }

    before { sign_in admin }

    def page = Nokogiri::HTML(response.body)
    def section(heading) = page.css("section").find { |node| node.at_css("h2")&.text&.squish == heading }

    describe "GET /admin" do
      it "shows totals, budgets, the run switch, the settings and the latest failures" do
        create(:report, show: show, kind: "agent", status: "failed", error_message: "Qloo returned 401",
                        finished_at: 1.minute.ago)
        SpendEntry.create!(bucket: "promo", kind: "llm", cost_usd: 1.25)

        get "/admin", headers: basic_auth

        expect(response).to have_http_status(:ok)
        expect(page.at_css("h1").text).to eq("Admin")
        expect(page.at_css("a[href='/admin/jobs']").text).to eq("Jobs")
        expect(section("Totals").text.squish).to include("Today", "This month", "New users", "Pitches")
        expect(section("Budgets").text.squish).to include("Promo", "$1.25 of $5.00")
        expect(section("New runs").text.squish).to include("Running")
        expect(section("Settings").at_css("input[name='settings[promo_budget_usd]']")["value"]).to eq("10.0")
        failures = section("Latest failed reports")
        expect(failures.text.squish).to include("Money Talks", "Qloo returned 401")
      end
    end

    describe "pausing new runs" do
      it "pauses with a reason, so Report.start! refuses with :paused, and logs who did it" do
        allow(Rails.logger).to receive(:info).and_call_original

        post "/admin/pause", params: { reason: "Qloo key rotation" }, headers: basic_auth

        expect(response).to redirect_to("/admin")
        expect(AppSettings.runs_paused?).to be(true)
        expect(AppSettings.get(:runs_paused_reason)).to eq("Qloo key rotation")
        expect(Rails.logger).to have_received(:info)
          .with(a_string_including("ops@example.com", "paused new runs", "Qloo key rotation"))
        expect { Report.start!(show: show, kind: "agent", user: owner) }
          .to raise_error(Entitlements::NotAllowed) { |error| expect(error.reason).to eq(:paused) }

        follow_redirect!(headers: basic_auth)
        expect(section("New runs").text.squish).to include("Paused", "Qloo key rotation")
      end

      it "refuses to pause without a reason, or with one too long to show" do
        post "/admin/pause", params: { reason: "  " }, headers: basic_auth
        expect(response).to redirect_to("/admin")
        expect(flash[:alert]).to eq("Give a reason for pausing. Users see it.")

        post "/admin/pause", params: { reason: "x" * 201 }, headers: basic_auth
        expect(flash[:alert]).to eq("Keep the reason to 200 characters or fewer.")
        expect(AppSettings.runs_paused?).to be(false)
      end

      it "resumes: clears the pause, its reason and the Qloo failure count, so reports start again" do
        AppSettings.pause_runs!("Qloo authentication failing")
        allow(AppSettings).to receive(:reset_taste_auth_failures!).and_call_original

        delete "/admin/pause", headers: basic_auth

        expect(response).to redirect_to("/admin")
        expect(AppSettings.runs_paused?).to be(false)
        expect(AppSettings.get(:runs_paused_reason)).to be_nil
        expect(AppSettings).to have_received(:reset_taste_auth_failures!)
        expect(Report.start!(show: show, kind: "snapshot", user: owner)).to be_persisted
      end
    end

    describe "PATCH /admin/settings" do
      let(:valid) do
        { promo_budget_usd: "20", judge_reserve_usd: "7.5", llm_daily_budget_usd: "8.25", promo_pro_until: "2026-11-20" }
      end

      it "saves the budgets and the promo date, and logs who changed what" do
        AppSettings.set(:promo_pro_until, "2026-11-06")
        allow(Rails.logger).to receive(:info).and_call_original

        patch "/admin/settings", params: { settings: valid }, headers: basic_auth

        expect(response).to redirect_to("/admin")
        expect(flash[:notice]).to eq("Settings saved.")
        expect(AppSettings.get(:promo_budget_usd)).to eq("20.0")
        expect(AppSettings.get(:judge_reserve_usd)).to eq("7.5")
        expect(AppSettings.get(:llm_daily_budget_usd)).to eq("8.25")
        expect(Entitlements.promo_until).to eq(Date.new(2026, 11, 20))
        expect(Llm::Budget.usage.dig(:promo, :ceiling)).to eq(BigDecimal("12.5"))
        expect(Rails.logger).to have_received(:info).with(a_string_including(
          "ops@example.com", "promo_budget_usd from 10.0 to 20.0", "judge_reserve_usd from 5.0 to 7.5",
          "llm_daily_budget_usd from 5.0 to 8.25", "promo_pro_until from 2026-11-06 to 2026-11-20"
        ))
      end

      it "re-renders with every error and saves nothing when a value is invalid" do
        patch "/admin/settings", headers: basic_auth,
                                 params: { settings: valid.merge(promo_budget_usd: "-1", llm_daily_budget_usd: "lots",
                                                                 promo_pro_until: "2026-13-40") }

        expect(response).to have_http_status(:unprocessable_content)
        errors = section("Settings").at_css("[role='alert']").text.squish
        expect(errors).to include("Promo budget must be a dollar amount, 0 or more.",
                                  "Daily LLM budget must be a dollar amount, 0 or more.",
                                  "Promo Pro until must be a date.")
        expect(section("Settings").at_css("input[name='settings[llm_daily_budget_usd]']")["value"]).to eq("lots")
        expect(Setting.count).to eq(0)
      end

      it "keeps CSRF protection on" do
        ActionController::Base.allow_forgery_protection = true
        patch "/admin/settings", params: { settings: valid }, headers: basic_auth
        expect(response).to have_http_status(:unprocessable_content)
        expect(Setting.count).to eq(0)
      ensure
        ActionController::Base.allow_forgery_protection = false
      end
    end
  end
end
