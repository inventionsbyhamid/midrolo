require "rails_helper"

RSpec.describe "Sponsor matches" do
  # The pipeline is a Creator feature (R45).
  let(:user) { create(:user, :subscribed) }
  let(:show) { create(:show, user: user) }
  let(:report) { create(:report, show: show, kind: "agent", status: "done") }
  let(:brand_match) { create(:sponsor_match, report: report, name: "Fieldnote Coffee") }
  let(:turbo) { { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" } }

  def page = Nokogiri::HTML5.fragment(response.body)

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
      # A fresh element each save, so its fade animation starts over every time.
      expect(saved.at_css("template").children.at_css(".status-saved-msg").text.squish).to eq("Saved")
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
      # The unsaved "pitched" mustn't reach an open pitch dialog's Mark as pitched either.
      expect(page.at_css("turbo-stream[target='#{ActionView::RecordIdentifier.dom_id(brand_match, :mark_pitched)}']")).to be_nil
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

    describe "a copy superseded by a newer report's (R48)" do
      let(:newer_report) { create(:report, show: show, kind: "agent", status: "done") }
      let!(:newer) do
        brand_match # the older copy first
        create(:sponsor_match, report: newer_report, brand_entity_id: brand_match.brand_entity_id,
                               name: "Fieldnote Coffee", status: "replied")
      end

      it "refuses a Turbo save with 409 and turns the form into the read-only status with a link to the newer copy" do
        patch sponsor_match_path(brand_match), params: { sponsor_match: { status: "won" } }, headers: turbo

        expect(response).to have_http_status(:conflict)
        expect(brand_match.reload.status).to eq("suggested")
        state = page.at_css("turbo-stream[action='replace'] template").children
                    .at_css("##{ActionView::RecordIdentifier.dom_id(brand_match, :status_form)}")
        expect(state.css("form, select")).to be_empty
        expect(state.text.squish).to include("Replied")
        link = state.at_css("a[href='#{show_report_path(show, newer_report, anchor: ActionView::RecordIdentifier.dom_id(newer))}']")
        expect(link.text.squish).to eq("Tracked on your latest report →")
        expect(state.at_css("[role='alert']").text).to include("Not saved")
      end

      it "sends a plain submit to the newer copy's card with a notice" do
        patch sponsor_match_path(brand_match), params: { sponsor_match: { status: "won" } }

        expect(response).to redirect_to(show_report_path(show, newer_report, anchor: ActionView::RecordIdentifier.dom_id(newer)))
        expect(flash[:notice]).to eq("Fieldnote Coffee is tracked on your latest report, so update it there.")
        expect(brand_match.reload.status).to eq("suggested")
      end

      it "still saves the newer copy" do
        patch sponsor_match_path(newer), params: { sponsor_match: { status: "won" } }, headers: turbo
        expect(response).to have_http_status(:ok)
        expect(newer.reload.status).to eq("won")
      end
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
      stub_plan(visible_matches: 1)

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
      stub_plan(visible_matches: 1)

      [ first, later ].each do |m|
        patch sponsor_match_path(m), params: { sponsor_match: { status: "saved" } }, headers: turbo
        expect(response).to have_http_status(:ok)
      end
    end

    context "without the pipeline on their plan (R45)" do
      before { stub_plan(pipeline: false) }

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
end
