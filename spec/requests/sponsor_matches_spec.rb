require "rails_helper"

RSpec.describe "Sponsor matches" do
  let(:user) { create(:user) }
  let(:show) { create(:show, user: user) }
  let(:report) { create(:report, show: show, kind: "agent", status: "done") }
  let(:brand_match) { create(:sponsor_match, report: report, name: "Fieldnote Coffee") }
  let(:turbo) { { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" } }

  def page = Nokogiri::HTML5.fragment(response.body)

  def stub_plan(**overrides)
    plan = Class.new(Entitlements::Plan) do
      overrides.each { |name, value| define_method(name) { value } }
    end.new
    allow(Entitlements).to receive(:for).and_return(plan)
  end

  it "requires sign in" do
    patch sponsor_match_path(brand_match), params: { sponsor_match: { status: "saved" } }
    expect(response).to redirect_to("/users/sign_in")
    expect(brand_match.reload.status).to eq("suggested")
  end

  context "when signed in" do
    before { sign_in user }

    it "saves the status and morphs the match's form in place with a polite Saved" do
      patch sponsor_match_path(brand_match), params: { sponsor_match: { status: "pitched" } }, headers: turbo

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(brand_match.reload.status).to eq("pitched")
      stream = page.at_css("turbo-stream[action='replace'][target='#{ActionView::RecordIdentifier.dom_id(brand_match, :status_form)}']")
      expect(stream["method"]).to eq("morph")
      form = stream.at_css("template").children.at_css("form")
      expect(form.at_css("select option[selected]")["value"]).to eq("pitched")
      saved = page.at_css("turbo-stream[action='update'][target='#{ActionView::RecordIdentifier.dom_id(brand_match, :status_saved)}']")
      expect(saved.text.squish).to eq("Saved")
    end

    it "saves notes and the follow-up date" do
      patch sponsor_match_path(brand_match), params: { sponsor_match: { notes: "Emailed Sam", follow_up_on: "2026-11-02" } },
                                       headers: turbo

      expect(brand_match.reload).to have_attributes(notes: "Emailed Sam", follow_up_on: Date.new(2026, 11, 2))
      expect(response.body).to include("Emailed Sam")
    end

    it "re-renders validation errors inline, with the notes panel open, and saves nothing" do
      patch sponsor_match_path(brand_match),
            params: { sponsor_match: { status: "pitched", notes: "a" * (SponsorMatch::NOTES_LIMIT + 1) } }, headers: turbo

      expect(response).to have_http_status(:unprocessable_content)
      expect(brand_match.reload).to have_attributes(status: "suggested", notes: nil)
      form = page.at_css("turbo-stream[action='replace'] template").children.at_css("form")
      expect(form.at_css("details")["open"]).not_to be_nil
      notes = form.at_css("textarea")
      expect(notes["aria-invalid"]).to eq("true")
      error = form.at_css("##{notes['aria-describedby'].split.last}")
      expect(error.text).to include("Notes can be at most #{SponsorMatch::NOTES_LIMIT} characters")
      expect(page.at_css("turbo-stream[action='update']")).to be_nil
    end

    it "ignores attributes the podcaster can't edit" do
      patch sponsor_match_path(brand_match), params: { sponsor_match: { status: "saved", name: "Hacked", fit_score: 100 } },
                                       headers: turbo
      expect(brand_match.reload).to have_attributes(status: "saved", name: "Fieldnote Coffee", fit_score: 80)
    end

    it "redirects a no-JavaScript submit back to the card on the report" do
      patch sponsor_match_path(brand_match), params: { sponsor_match: { status: "saved" } }

      expect(response).to redirect_to(show_report_path(show, report, anchor: ActionView::RecordIdentifier.dom_id(brand_match)))
      expect(flash[:notice]).to eq("Saved Fieldnote Coffee.")
      expect(brand_match.reload.status).to eq("saved")
    end

    it "404s for another user's match" do
      other = create(:sponsor_match, status: "suggested")
      patch sponsor_match_path(other), params: { sponsor_match: { status: "won" } }, headers: turbo
      expect(response).to have_http_status(:not_found)
      expect(other.reload.status).to eq("suggested")
    end

    it "404s for a Snapshot match beyond the plan's visible limit, naming no brand" do
      # The production 404 page: the test env's detailed error page quotes this spec's source.
      config = Rails.application.env_config
      detailed = config["action_dispatch.show_detailed_exceptions"]
      config["action_dispatch.show_detailed_exceptions"] = false
      snapshot = create(:report, show: show, kind: "snapshot", status: "done")
      visible = create(:sponsor_match, report: snapshot, position: 1, name: "Visible Brand")
      locked = create(:sponsor_match, report: snapshot, position: 2, name: "Locked Brand")
      stub_plan(visible_matches_limit: 1)

      patch sponsor_match_path(visible), params: { sponsor_match: { status: "saved" } }, headers: turbo
      expect(response).to have_http_status(:ok)

      patch sponsor_match_path(locked), params: { sponsor_match: { status: "saved" } }, headers: turbo
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("Locked Brand")
      expect(locked.reload.status).to eq("suggested")
    ensure
      config["action_dispatch.show_detailed_exceptions"] = detailed
    end

    it "edits any match on an agent report, whatever the visible limit (R44)" do
      first = create(:sponsor_match, report: report, position: 1)
      later = create(:sponsor_match, report: report, position: 2)
      stub_plan(visible_matches_limit: 1)

      [ first, later ].each do |m|
        patch sponsor_match_path(m), params: { sponsor_match: { status: "saved" } }, headers: turbo
        expect(response).to have_http_status(:ok)
      end
    end

    context "without the pipeline on their plan (R45)" do
      before { stub_plan(pipeline?: false) }

      it "sends a Turbo submit to pricing with a notice and saves nothing" do
        patch sponsor_match_path(brand_match), params: { sponsor_match: { status: "pitched" } }, headers: turbo

        expect(response).to redirect_to(pricing_path)
        expect(response).to have_http_status(:see_other)
        expect(flash[:notice]).to include("Creator plan")
        expect(brand_match.reload.status).to eq("suggested")
      end

      it "sends a plain submit to pricing too" do
        patch sponsor_match_path(brand_match), params: { sponsor_match: { notes: "Hi" } }
        expect(response).to redirect_to(pricing_path)
        expect(brand_match.reload.notes).to be_nil
      end
    end
  end

  describe "GET /pricing (temporary, R47)" do
    it "redirects to the account page for now" do
      get "/pricing"
      expect(response).to redirect_to("/account")
    end
  end
end
