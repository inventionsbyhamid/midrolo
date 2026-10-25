require "rails_helper"

RSpec.describe "Reports" do
  include ActiveJob::TestHelper

  # Creator: full reports and the pipeline.
  let(:user) { create(:user, :subscribed) }
  let(:show) { create(:show, user: user) }

  it "requires sign in" do
    post "/shows/#{show.id}/reports", params: { kind: "snapshot" }
    expect(response).to redirect_to("/users/sign_in")
  end

  context "when signed in" do
    before { sign_in user }

    describe "POST /shows/:id/reports" do
      it "creates a queued report, enqueues the job and redirects to it" do
        expect { post show_reports_path(show), params: { kind: "snapshot" } }
          .to change(show.reports, :count).by(1).and have_enqueued_job(BuildSnapshotJob)
        expect(response).to redirect_to(show_report_path(show, show.reports.last))
      end

      it "creates one report on a double submit and redirects both to it" do
        post show_reports_path(show), params: { kind: "agent" }
        first = response.location
        expect { post show_reports_path(show), params: { kind: "agent" } }.not_to change(Report, :count)
        expect(response.location).to eq(first)
      end

      it "rejects an unknown kind" do
        post show_reports_path(show), params: { kind: "bogus" }
        expect(response).to redirect_to(show_path(show))
        expect(Report.count).to eq(0)
      end

      it "redirects back to the show with the plan's reason as an upgrade prompt (R63)" do
        4.times { create(:report, show: show, kind: "agent", status: "done", spend_bucket: "paid") }
        expect { post show_reports_path(show), params: { kind: "agent" } }.not_to change(Report, :count)
        expect(response).to redirect_to(show_path(show))
        expect(flash[:upgrade]).to eq("reason" => "limit", "kind" => "agent", "bucket" => "paid", "used" => 4,
                                      "in_flight" => 0, "limit" => 4, "period" => "billing period")

        follow_redirect!
        prompt = Nokogiri::HTML(response.body).at_css(".upgrade-prompt")
        expect(prompt.text.squish).to include("You've used 4 of 4 reports this billing period")
        expect(prompt.at_css("a[href='#{pricing_path}']").text).to eq("See plans")
      end

      it "shows the numbers from when it refused, even if a report in progress fails before the page loads (R63)" do
        3.times { create(:report, show: show, kind: "agent", status: "done", spend_bucket: "paid") }
        running = create(:report, show: create(:show, user: user), kind: "agent", status: "running", started_at: 1.minute.ago)
        post show_reports_path(show), params: { kind: "agent" }
        running.mark_failed!

        follow_redirect!
        expect(Nokogiri::HTML(response.body).at_css(".upgrade-prompt").text.squish)
          .to include("You've used 3 of 4 reports this billing period, and 1 more is in progress")
      end

      it "tells a subscriber at today's capacity to try tomorrow, not to join a waitlist (R63a)" do
        allow(Llm::Budget).to receive(:allow?).with(:paid).and_return(false)
        post show_reports_path(show), params: { kind: "agent" }
        follow_redirect!
        prompt = Nokogiri::HTML(response.body).at_css(".upgrade-prompt")
        expect(prompt.text.squish).to include("We've hit today's limit for full reports. Try again tomorrow.")
        expect(prompt.text).not_to include("waitlist")
      end

      it "tells a free user full reports are on Creator and up" do
        sign_in(free_user = create(:user))
        post show_reports_path(create(:show, user: free_user)), params: { kind: "agent" }
        follow_redirect!
        expect(Nokogiri::HTML(response.body).at_css(".upgrade-prompt").text.squish)
          .to include("Full agent reports are on Creator and up", "See plans")
      end

      it "404s for another user's show" do
        other = create(:show)
        post show_reports_path(other), params: { kind: "snapshot" }
        expect(response).to have_http_status(:not_found)
        expect(Report.count).to eq(0)
      end
    end

    describe "GET /shows/:id/reports/:id" do
      it "subscribes to the report stream and shows skeleton sections and the rail" do
        report = create(:report, show: show, kind: "agent", status: "running")
        create(:agent_step, report: report, label: "Reading your last 15 episodes…")
        get show_report_path(show, report)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("<turbo-cable-stream-source", "Researching your audience…",
                                         "Reading your last 15 episodes…", 'aria-live="polite"', "Show agent steps")
        Report::SECTIONS.each { |name| expect(response.body).to include(%(id="report_#{name}")) }
        expect(response.body.scan(/class="skeleton"/).size).to be >= 5
        expect(response.body).to include("Media kit", show_media_kit_path(show), 'name="turbo-refresh-method" content="morph"')
        expect(response.body).to match(/<details[^>]*id="agent_rail_report_#{report.id}"[^>]* open[ >]/)
        expect(response.body).to include(%(id="agent_steps_report_#{report.id}"))
      end

      it "folds the steps into How we built this once the report is done: no rail, one column (R99)" do
        report = create(:report, show: show, kind: "agent", status: "done", summary: "Founders who love finance tools.")
        create(:agent_step, report: report, label: "Reading your last 15 episodes…", status: "ok")
        create_list(:sponsor_match, 3, report: report)
        get show_report_path(show, report)
        page = Nokogiri::HTML(response.body)

        expect(page.at_css("aside[aria-label='Agent steps']")).to be_nil
        expect(page.at_css(".report-page")["class"]).not_to include("report-page-live")
        expect(page.at_css("#report_how details:not([open])").text).to include("Reading your last 15 episodes…")
        glance = page.css("#report_summary ul.glance > li")
        expect(glance.size).to eq(3)
        expect(glance.last.text.squish).to include("Write your first pitch to")
        expect(page.css("#pitch_dialog")).to be_present
      end

      it "disables Re-run while active and enables it when finished" do
        report = create(:report, show: show, status: "running")
        get show_report_path(show, report)
        expect(response.body).to match(/<button[^>]*disabled[^>]*>Run again/)

        report.update!(status: "done")
        get show_report_path(show, report)
        expect(response.body).to include(show_reports_path(show, kind: "snapshot"))
        expect(response.body).not_to match(/<button[^>]*disabled[^>]*>Run again/)
      end

      it "re-runs the same kind" do
        report = create(:report, show: show, kind: "agent", status: "done")
        get show_report_path(show, report)
        expect(response.body).to include(show_reports_path(show, kind: "agent"))
      end

      it "renders saved sections" do
        report = create(:report, show: show, status: "done", summary: "Money-minded listeners.")
        get show_report_path(show, report)
        expect(response.body).to include("Money-minded listeners.", "Report ready")
      end

      it "renders the saved seeds with their sources and the names Qloo couldn't match" do
        seeds = { "entities" => [ { "id" => "q1", "name" => "Index Fund Mornings", "type" => "podcast", "source" => "You listed it" } ],
                  "tags" => [ { "id" => "t1", "name" => "Personal Finance", "source" => "Topic: personal finance" } ],
                  "unresolved" => [ "Nonexistent Pod Zzz" ] }
        report = create(:report, show: show, status: "needs_input", profile_kind: "proxy", seeds: seeds)
        get show_report_path(show, report)
        seeds_html = Nokogiri::HTML(response.body).at_css("#report_seeds")
        expect(seeds_html.css("[data-seed]").map { |li| li.text.squish })
          .to eq([ "Index Fund Mornings You listed it", "Personal Finance Topic: personal finance" ])
        expect(seeds_html.text).to include("Nonexistent Pod Zzz")
        expect(seeds_html.text).not_to include("entities")
      end

      it "shows the friendly failure message with Try again" do
        report = create(:report, show: show, status: "failed", error_message: Report::FAILURE_MESSAGE)
        get show_report_path(show, report)
        expect(response.body).to include(Report::FAILURE_MESSAGE, "Try again", "Something went wrong")
      end

      it "asks for comparable shows inline when the report needs input" do
        report = create(:report, show: show, kind: "agent", status: "needs_input")
        get show_report_path(show, report)
        page = Nokogiri::HTML(response.body)
        expect(page.text.squish).to include("We need a little more to go on. Tell us 2 or 3 shows your listeners also love.")
        form = page.at_css("#report_seeds form[action='#{show_path(show)}']")
        expect(form.at_css("input[name='rerun']")["value"]).to eq("agent")
        expect(response.body).to include(edit_show_path(show))
        Report::SECTIONS.each { |name| expect(response.body).to include(%(id="report_#{name}")) }
        expect(page.css(".skeleton")).to be_empty
      end

      it "leads a snapshot that needs input with the ask, not the upsell" do
        report = create(:report, show: show, kind: "snapshot", status: "needs_input")
        get show_report_path(show, report)
        page = Nokogiri::HTML(response.body)
        expect(page.at_css("#report_seeds form input[name='rerun']")["value"]).to eq("snapshot")
        expect(page.text).not_to include("This is your free Snapshot")
      end

      it "doesn't stack the upsell under a failed snapshot's Try again" do
        report = create(:report, show: show, kind: "snapshot", status: "failed", error_message: Report::FAILURE_MESSAGE)
        get show_report_path(show, report)
        expect(response.body).to include("Try again")
        expect(response.body).not_to include("This is your free Snapshot")
      end

      context "while new runs are paused (R82)" do
        before { AppSettings.pause_runs!("Back after maintenance") }

        def page = Nokogiri::HTML(response.body)
        def disabled_buttons = page.css("button[disabled]").map { |button| button.text.squish }

        it "disables Re-run and Try again and says why, with the notify-me box" do
          report = create(:report, show: show, kind: "agent", status: "failed", error_message: Report::FAILURE_MESSAGE)
          get show_report_path(show, report)

          expect(page.css("form[action^='#{show_reports_path(show)}']")).to be_empty
          expect(disabled_buttons).to include("Run again", "Try again")
          paused = page.at_css("[data-runs-paused]")
          expect(paused.at_css("[role='status']").text.squish).to eq("New reports are paused. We'll email you when they're back.")
          expect(paused.at_css("form[action='#{waitlist_entries_path}'] input[name='price_key']")["value"]).to eq("notify")
        end

        it "disables a finished Snapshot's Run full report too" do
          report = create(:report, show: show, kind: "snapshot", status: "done")
          get show_report_path(show, report)

          expect(page.css("form[action^='#{show_reports_path(show)}']")).to be_empty
          expect(disabled_buttons).to include("Run again", "Run full report")
        end

        it "shows them live again once runs resume" do
          AppSettings.resume_runs!
          report = create(:report, show: show, kind: "agent", status: "failed", error_message: Report::FAILURE_MESSAGE)
          get show_report_path(show, report)

          expect(page.css("form[action^='#{show_reports_path(show)}']").size).to eq(2)
          expect(page.at_css("[data-runs-paused]")).to be_nil
        end
      end

      it "leaves the MapLibre stylesheet to the map controller instead of blocking first paint" do
        report = create(:report, show: show, kind: "agent", status: "done",
                                 heatmap: { "location" => "US", "country" => "US",
                                            "points" => [ { "lat" => 40.7, "lng" => -74.0, "affinity" => 0.9, "label" => "New York" } ] })
        get show_report_path(show, report)
        page = Nokogiri::HTML(response.body)
        expect(page.css("head link[href*='maplibre-gl']")).to be_empty
        expect(page.at_css("[data-controller~='map']")["data-map-stylesheet-value"])
          .to match(%r{\Ahttps://cdn\.jsdelivr\.net/npm/maplibre-gl@\d+\.\d+\.\d+/dist/maplibre-gl\.css\z})
      end

      it "renders a finished report's matches with one query, plus one to find brands tracked on a newer report (R48)" do
        report = create(:report, show: show, kind: "agent", status: "done")
        create_list(:sponsor_match, 6, report: report)
        queries = []
        sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| queries << p[:sql] if p[:sql] =~ /FROM "sponsor_matches"/ }
        get show_report_path(show, report)
        ActiveSupport::Notifications.unsubscribe(sub)
        expect(Nokogiri::HTML(response.body).css("[data-filter-target='item']").size).to eq(6)
        expect(queries.size).to eq(2)
      end

      it "renders each card's pipeline form, editable or superseded (R48), without a query per match" do
        report = create(:report, show: show, kind: "agent", status: "done")
        count_queries = lambda do
          queries = 0
          sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| queries += 1 unless p[:name] == "SCHEMA" }
          get show_report_path(show, report)
          ActiveSupport::Notifications.unsubscribe(sub)
          queries
        end
        create(:sponsor_match, report: report)
        count_queries.call # the first request also records the sign-in (Devise trackable)
        with_one = count_queries.call
        create_list(:sponsor_match, 5, report: report)
        newer = create(:report, show: show, kind: "agent", status: "done")
        report.sponsor_matches.first(3).each do |match|
          create(:sponsor_match, report: newer, brand_entity_id: match.brand_entity_id, status: "pitched")
        end

        expect(count_queries.call).to eq(with_one)
        page = Nokogiri::HTML(response.body)
        expect(page.css("form[data-controller='status-form']").size).to eq(3)
        expect(page.css("[data-superseded]").size).to eq(3)
      end

      it "404s for another user's report" do
        other = create(:report)
        get show_report_path(other.show, other)
        expect(response).to have_http_status(:not_found)
      end

      it "404s when the report belongs to a different show" do
        mine = create(:report, show: show)
        other_show = create(:show, user: user)
        get show_report_path(other_show, mine)
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "show hub and index" do
      it "posts real forms for snapshot and agent reports" do
        get show_path(show)
        expect(response.body).to include(show_reports_path(show, kind: "snapshot"), show_reports_path(show, kind: "agent"),
                                         "Get my free Snapshot", "Run full report")
      end

      it "disables both and links to the running report while one is active" do
        report = create(:report, show: show, status: "running")
        get show_path(show)
        expect(response.body).to include("Research in progress", show_report_path(show, report))
        expect(response.body).not_to include(show_reports_path(show, kind: "snapshot"))
      end

      it "lists the latest report status without N+1 queries" do
        shows = create_list(:show, 4, user: user)
        shows.each { |s| create(:report, show: s, status: "done") }
        queries = []
        sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| queries << p[:sql] if p[:sql] =~ /FROM "reports"/ }
        get shows_path
        ActiveSupport::Notifications.unsubscribe(sub)
        expect(response.body).to include("Report ready")
        expect(queries.size).to eq(1)
      end
    end
  end
end
