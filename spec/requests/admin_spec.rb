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

        it "opens for a signed-in admin on the admin flag alone when ADMIN_USERNAME or ADMIN_PASSWORD is unset (R144)" do
          sign_in admin
          with_admin_env(username: nil) do
            get path
            expect(response).to have_http_status(:ok)
            expect(response.headers["WWW-Authenticate"]).to be_nil
          end
          with_admin_env(password: "") do
            get path
            expect(response).to have_http_status(:ok)
          end
        end

        it "stays not found for a non-admin or a signed-out visitor when the basic auth variables are unset (R144)" do
          with_admin_env(username: nil, password: nil) do
            get path
            expect(response).to have_http_status(:not_found)
            sign_in create(:user)
            get path
            expect(response).to have_http_status(:not_found)
          end
        end
      end
    end
  end

  describe "access to what changes things (R68)" do
    # A request answered with the 404 raises, so it never writes the session cookie: each one signs in afresh.
    [ [ :patch, "/admin/settings" ], [ :post, "/admin/pause" ], [ :delete, "/admin/pause" ],
      [ :post, "/admin/jobs/applications/midrolo/jobs/job-1/retry" ],
      [ :post, "/admin/jobs/applications/midrolo/jobs/job-1/discard" ],
      [ :post, "/admin/jobs/applications/midrolo/jobs/job-1/dispatch" ],
      [ :post, "/admin/jobs/applications/midrolo/jobs/bulk_retries" ],
      [ :post, "/admin/jobs/applications/midrolo/jobs/bulk_discards" ],
      [ :post, "/admin/jobs/applications/midrolo/queues/default/pause" ],
      [ :delete, "/admin/jobs/applications/midrolo/queues/default/pause" ],
      [ :patch, "/admin/jobs/applications/midrolo/recurring_tasks/nightly" ] ].each do |method, path|
      it "#{method.upcase} #{path}: 404 for a non-admin, with or without the env, 401 for an admin without basic auth" do
        params = { reason: "x", settings: { promo_budget_usd: "1" } }

        sign_in create(:user)
        public_send(method, path, params: params, headers: basic_auth)
        expect(response).to have_http_status(:not_found)

        sign_in create(:user)
        with_admin_env(username: nil, password: nil) { public_send(method, path, params: params) }
        expect(response).to have_http_status(:not_found)

        sign_in admin
        public_send(method, path, params: params)
        expect(response).to have_http_status(:unauthorized)

        expect(Setting.count).to eq(0)
      end
    end

    context "with CSRF protection on" do
      around do |example|
        ActionController::Base.allow_forgery_protection = true
        example.run
      ensure
        ActionController::Base.allow_forgery_protection = false
      end

      it "checks who is asking before the token, so a token-less POST doesn't reveal the area" do
        sign_in create(:user)
        post "/admin/pause", params: { reason: "x" }, headers: basic_auth
        expect(response).to have_http_status(:not_found)

        post "/admin/pause", params: { reason: "x" }, headers: basic_auth
        expect(response).to have_http_status(:not_found)

        sign_in admin
        post "/admin/pause", params: { reason: "x" }
        expect(response).to have_http_status(:unauthorized)
        expect(AppSettings.runs_paused?).to be(false)
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

      it "shows Qloo calls and Qloo cost per done report, and each paid plan's margin at its caps (R94)" do
        AppSettings.set(:qloo_cost_per_call_usd, "0.002")
        create(:report, show: show, kind: "agent", status: "done", taste_calls: 30)
        create(:report, show: show, kind: "agent", status: "done", taste_calls: 20)
        create(:report, show: show, kind: "snapshot", status: "done", taste_calls: 8)

        get "/admin", headers: basic_auth

        totals = section("Totals").css("tr").to_h { |tr| [ tr.at_css("th")&.text&.squish, tr.css("td").map { |td| td.text.squish } ] }
        expect(totals["Qloo calls per done full report"]).to eq(%w[25.0 25.0])
        expect(totals["Qloo calls per done Snapshot"]).to eq(%w[8.0 8.0])
        expect(totals["Qloo cost per done full report"]).to eq(%w[$0.05 $0.05])
        expect(totals["Qloo cost per done Snapshot"]).to eq(%w[$0.02 $0.02])

        margins = section("Go live check")
        rows = margins.css("tbody tr").to_h { |tr| [ tr.at_css("th").text.squish, tr.css("td").map { |td| td.text.squish } ] }
        expect(rows.keys).to eq([ "Creator monthly", "Creator yearly", "Pro monthly", "Pro yearly", "Sprint" ])
        # Every report counts at the hard ceiling of 40 calls (R130).
        expect(rows["Creator monthly"]).to eq([ "$19.00", "$17.46", "$3.60", "320", "$0.64", "75%" ])
        expect(margins.text.squish).to include("$0.04 a pitch", "an estimate",
                                               "Qloo: 40 calls a full report and 40 a Snapshot (the hard cap per report")
        expect(margins.at_css("[role='alert']")).to be_nil
      end

      it "warns when BILLING_MODE asks for live but the go live check keeps the waitlist (R94)" do
        with_billing_env("BILLING_MODE" => "live", "DODO_API_KEY" => "key", "DODO_ENVIRONMENT" => "live_mode") do
          get "/admin", headers: basic_auth
        end

        alert = section("Go live check").at_css("[role='alert']").text.squish
        expect(alert).to include("BILLING_MODE is live, but paid plans show the waitlist", "The Qloo cost per call isn't set")
        expect(section("Go live check").text.squish).to include("Not set")
      end

      it "shows Qloo calls today, this minute and free and promo runs' calls against their caps (R92, R95, R108)" do
        allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
        2.times { Taste::CallGuard.new.acquire! }
        Taste::CallGuard.lane(:capped) { Taste::CallGuard.new.acquire! }

        get "/admin", headers: basic_auth

        meters = section("Qloo calls").css("[role='meter']").to_h { |meter| [ meter["aria-label"], meter.at_css(".meter-value").text ] }
        expect(meters).to include("Qloo calls today" => "3 / 100", "This minute" => "3 / 30", "Free and promo runs today" => "1 / 40")
        expect(section("Settings").at_css("input[name='settings[qloo_daily_call_limit]']")["value"]).to eq("100")
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

      it "emails the notify list through a job when it resumes, as the paused notice promises (R81)" do
        AppSettings.pause_runs!("Qloo key rotation")

        expect { delete "/admin/pause", headers: basic_auth }.to have_enqueued_job(RunsResumedMailJob).once
      end

      it "emails nobody when runs weren't paused" do
        expect { delete "/admin/pause", headers: basic_auth }.not_to have_enqueued_job(RunsResumedMailJob)
      end
    end

    describe "PATCH /admin/settings" do
      let(:valid) do
        { promo_budget_usd: "20", judge_reserve_usd: "7.5", llm_daily_budget_usd: "8.25", promo_pro_until: "2026-11-20",
          qloo_daily_call_limit: "100", qloo_cost_per_call_usd: "", qloo_free_share: "0.4" }
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

      it "saves the Qloo daily call limit (R92) and the Qloo cost per call (R94)" do
        patch "/admin/settings", params: { settings: valid.merge(qloo_daily_call_limit: "500", qloo_cost_per_call_usd: "0.003") },
                                 headers: basic_auth

        expect(response).to redirect_to("/admin")
        expect(Taste::CallGuard.daily_limit).to eq(500)
        expect(Billing::Margins.cost_per_call).to eq(BigDecimal("0.003"))
      end

      it "re-renders with every error and saves nothing when a value is invalid" do
        patch "/admin/settings", headers: basic_auth,
                                 params: { settings: valid.merge(promo_budget_usd: "-1", llm_daily_budget_usd: "lots",
                                                                 promo_pro_until: "2026-13-40", qloo_daily_call_limit: "-5") }

        expect(response).to have_http_status(:unprocessable_content)
        errors = section("Settings").at_css("[role='alert']").text.squish
        expect(errors).to include("Promo budget must be a dollar amount, 0 or more.",
                                  "Daily LLM budget must be a dollar amount, 0 or more.",
                                  "Promo Pro until must be a date.", "Qloo calls a day must be a whole number, 0 or more.")
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
