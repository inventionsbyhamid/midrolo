require "rails_helper"

RSpec.describe "Reports" do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
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

      it "redirects back with a friendly flash when not allowed" do
        allow(Report).to receive(:start!).and_raise(Entitlements::NotAllowed.new(:limit))
        post show_reports_path(show), params: { kind: "agent" }
        expect(response).to redirect_to(show_path(show))
        expect(flash[:alert]).to be_present
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
        report = create(:report, show: show, status: "running")
        create(:agent_step, report: report, label: "Reading your last 15 episodes…")
        get show_report_path(show, report)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("<turbo-cable-stream-source", "Researching your audience…",
                                         "Reading your last 15 episodes…", 'aria-live="polite"', "Show agent steps")
        Report::SECTIONS.each { |name| expect(response.body).to include(%(id="report_#{name}")) }
        expect(response.body.scan(/class="skeleton"/).size).to be >= 5
        expect(response.body).to include("Media kit", "Coming soon", 'name="turbo-refresh-method" content="morph"')
        expect(response.body).to match(/<details[^>]*id="agent_rail_report_#{report.id}"[^>]* open[ >]/)
        expect(response.body).to include(%(id="agent_steps_report_#{report.id}"))
      end

      it "disables Re-run while active and enables it when finished" do
        report = create(:report, show: show, status: "running")
        get show_report_path(show, report)
        expect(response.body).to match(/<button[^>]*disabled[^>]*>Re-run/)

        report.update!(status: "done")
        get show_report_path(show, report)
        expect(response.body).to include(show_reports_path(show, kind: "snapshot"))
        expect(response.body).not_to match(/<button[^>]*disabled[^>]*>Re-run/)
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

      it "shows the friendly failure message with Try again" do
        report = create(:report, show: show, status: "failed", error_message: Report::FAILURE_MESSAGE)
        get show_report_path(show, report)
        expect(response.body).to include(Report::FAILURE_MESSAGE, "Try again", "Something went wrong")
      end

      it "shows the needs-input card linking to the show's edit page" do
        report = create(:report, show: show, status: "needs_input")
        get show_report_path(show, report)
        expect(response.body).to include("We need a little more to go on", edit_show_path(show))
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
