require "rails_helper"

RSpec.describe "Pipeline" do
  include ActionView::RecordIdentifier

  let(:user) { create(:user) }
  let(:show) { create(:show, user: user, title: "The Founder's Ledger") }
  let(:report) { create(:report, show: show, kind: "agent", status: "done") }

  around { |example| travel_to(Date.new(2026, 10, 25)) { example.run } }

  def page = Nokogiri::HTML(response.body)

  def stub_plan(**overrides)
    plan = Class.new(Entitlements::Plan) do
      overrides.each { |name, value| define_method(name) { value } }
    end.new
    allow(Entitlements).to receive(:for).and_return(plan)
  end

  def stage(status) = page.at_css("#stage_#{status}")

  def brands_in(status) = stage(status).css("[data-pipeline-entry] h3").map { |h| h.text.squish }

  it "requires sign in" do
    get pipeline_path
    expect(response).to redirect_to("/users/sign_in")
  end

  context "when signed in" do
    before { sign_in user }

    it "groups tracked brands by status, in pipeline order" do
      create(:sponsor_match, report: report, name: "Lost Co", status: "lost")
      create(:sponsor_match, report: report, name: "Saved Co", status: "saved")
      create(:sponsor_match, report: report, name: "Won Co", status: "won")
      create(:sponsor_match, report: report, name: "Pitched Co", status: "pitched")
      create(:sponsor_match, report: report, name: "Replied Co", status: "replied")
      create(:sponsor_match, report: report, name: "Suggested Co", status: "suggested")

      get pipeline_path

      expect(response).to have_http_status(:ok)
      expect(page.css("[data-pipeline-stage]").map { |s| s["id"] }).to eq(%w[stage_saved stage_pitched stage_replied stage_won stage_lost])
      expect(brands_in("pitched")).to eq([ "Pitched Co" ])
      expect(brands_in("won")).to eq([ "Won Co" ])
      expect(response.body).not_to include("Suggested Co")
      expect(page.at_css("nav[aria-label='Pipeline stages']").text.squish).to include("Saved 1", "Pitched 1", "Lost 1")
    end

    it "shows each brand's show, fit, tier, notes excerpt, follow-up date and a link to its card in the report" do
      match = create(:sponsor_match, report: report, name: "Fieldnote Coffee", status: "pitched", fit_score: 91,
                                     tier: "easy_yes", notes: "Emailed Sam at partnerships. #{'Very long note. ' * 30}",
                                     follow_up_on: Date.new(2026, 11, 2))
      get pipeline_path

      entry = stage("pitched").at_css("[data-pipeline-entry]")
      expect(entry.text.squish).to include("Fieldnote Coffee", "The Founder's Ledger", "Easy yes", "Emailed Sam at partnerships.")
      expect(entry.at_css("[role='meter']")["aria-valuenow"]).to eq("91")
      expect(entry.at_css("[data-pipeline-note]").text.squish.length).to be < 200
      expect(entry.at_css("time[datetime='2026-11-02']").text.squish).to eq("Nov 2")
      expect(entry.at_css("a[href='#{show_report_path(show, report, anchor: dom_id(match))}']")).to be_present
    end

    it "highlights follow-ups due today and overdue" do
      create(:sponsor_match, report: report, name: "Today Co", status: "pitched", follow_up_on: Date.new(2026, 10, 25))
      create(:sponsor_match, report: report, name: "Late Co", status: "pitched", follow_up_on: Date.new(2026, 10, 20))
      create(:sponsor_match, report: report, name: "Later Co", status: "pitched", follow_up_on: Date.new(2026, 11, 20))

      get pipeline_path

      entries = stage("pitched").css("[data-pipeline-entry]").index_by { |e| e.at_css("h3").text.squish }
      expect(entries["Today Co"]["data-follow-up"]).to eq("today")
      expect(entries["Today Co"].at_css(".pipeline-follow-up .badge").text).to eq("Due today")
      expect(entries["Late Co"]["data-follow-up"]).to eq("overdue")
      expect(entries["Late Co"].at_css(".pipeline-follow-up .badge").text).to eq("Overdue")
      expect(entries["Later Co"]["data-follow-up"]).to eq("upcoming")
      expect(entries["Later Co"].css(".pipeline-follow-up .badge").map(&:text)).not_to include("Due today", "Overdue")
      expect(brands_in("pitched")).to eq([ "Late Co", "Today Co", "Later Co" ]) # soonest follow-up first
      expect(page.text.squish).to include("1 follow-up overdue", "1 due today")
    end

    it "lists brands across all the user's shows, never another user's" do
      second_show = create(:show, user: user, title: "Side Hustle Hour")
      second = create(:report, show: second_show, kind: "agent", status: "done")
      create(:sponsor_match, report: report, name: "Mine One", status: "saved")
      create(:sponsor_match, report: second, name: "Mine Two", status: "saved")
      create(:sponsor_match, name: "Someone Else's", status: "saved")

      get pipeline_path

      expect(brands_in("saved")).to contain_exactly("Mine One", "Mine Two")
      expect(response.body).to include("Side Hustle Hour")
      expect(response.body).not_to include("Someone Else&#39;s", "Someone Else's")
    end

    describe "one entry per show and brand (R46)" do
      let(:newer) { create(:report, show: show, kind: "agent", status: "done") }

      it "keeps the copy from the newest report" do
        create(:sponsor_match, report: report, brand_entity_id: "b1", name: "Fieldnote", status: "pitched")
        create(:sponsor_match, report: newer, brand_entity_id: "b1", name: "Fieldnote", status: "won")

        get pipeline_path

        expect(page.css("[data-pipeline-entry]").size).to eq(1)
        expect(brands_in("won")).to eq([ "Fieldnote" ])
      end

      it "keeps a brand the newest report no longer has" do
        create(:sponsor_match, report: report, brand_entity_id: "b1", name: "Fieldnote", status: "pitched")
        create(:sponsor_match, report: newer, brand_entity_id: "b2", name: "Other", status: "suggested")

        get pipeline_path
        expect(brands_in("pitched")).to eq([ "Fieldnote" ])
      end

      it "drops a brand moved back to suggested on the newest finished report" do
        create(:sponsor_match, report: report, brand_entity_id: "b1", name: "Fieldnote", status: "pitched")
        create(:sponsor_match, report: newer, brand_entity_id: "b1", name: "Fieldnote", status: "suggested")

        get pipeline_path
        expect(page.css("[data-pipeline-entry]")).to be_empty
      end

      it "doesn't let a re-run still in progress hide brands before they carry forward" do
        create(:sponsor_match, report: report, brand_entity_id: "b1", name: "Fieldnote", status: "pitched")
        running = create(:report, show: show, kind: "agent", status: "running", started_at: Time.current)
        create(:sponsor_match, report: running, brand_entity_id: "b1", name: "Fieldnote", status: "suggested")

        get pipeline_path
        expect(brands_in("pitched")).to eq([ "Fieldnote" ])
      end

      it "keeps the same brand on two shows apart" do
        other = create(:report, show: create(:show, user: user), kind: "agent", status: "done")
        create(:sponsor_match, report: report, brand_entity_id: "b1", name: "Fieldnote", status: "saved")
        create(:sponsor_match, report: other, brand_entity_id: "b1", name: "Fieldnote", status: "saved")

        get pipeline_path
        expect(brands_in("saved")).to eq(%w[Fieldnote Fieldnote])
      end
    end

    it "explains how to add brands when the pipeline is empty" do
      create(:sponsor_match, report: report, status: "suggested")
      get pipeline_path

      empty = page.at_css(".empty-state")
      expect(empty.text.squish).to include("Your pipeline is empty", "Saved")
      expect(empty.at_css("a[href='#{shows_path}']")).to be_present
      expect(page.css("[data-pipeline-stage]")).to be_empty
    end

    it "is linked from the app nav" do
      get pipeline_path
      expect(page.at_css("nav[aria-label='Main'] a[href='#{pipeline_path}'][aria-current='page']")).to be_present
    end

    context "without the pipeline on their plan (R45)" do
      before { stub_plan(pipeline?: false) }

      it "redirects to pricing with a notice" do
        get pipeline_path
        expect(response).to redirect_to(pricing_path)
        2.times { follow_redirect! } # the temporary /pricing goes on to /account (R47)
        expect(Nokogiri::HTML(response.body).at_css(".flash-notice").text.squish).to eq(PipelineGate::UPSELL)
      end
    end
  end
end
