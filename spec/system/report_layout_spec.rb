require "rails_helper"

# Checks the compiled report CSS in a real browser: rules only between visible sections, the first visible one
# flush (the :not(... ~ *) selector), and the summary keeping its line breaks.
RSpec.describe "Report layout" do
  include Warden::Test::Helpers

  let(:user) { create(:user) }
  let(:show) { create(:show, user: user) }
  let(:seeds) { { "entities" => [ { "id" => "q1", "name" => "Index Fund Mornings", "source" => "You listed it" } ], "tags" => [] } }

  before { login_as(user, scope: :user) }

  def computed_style(selector, property)
    evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json})).getPropertyValue(#{property.to_json})")
  end

  it "rules between visible sections, sits the first one flush and keeps summary line breaks" do
    report = create(:report, show: show, kind: "agent", status: "done", profile_kind: "proxy", seeds: seeds,
                             summary: "First line.\nSecond line.")
    visit show_report_path(show, report)

    expect(page).to have_css("#report_seeds", text: "Index Fund Mornings")
    expect(computed_style("#report_summary", "padding-top")).to eq("0px")
    expect(computed_style("#report_summary", "border-top-width")).to eq("0px")
    expect(computed_style("#report_seeds", "border-top-width")).to eq("1px")
    expect(computed_style(".report-summary", "white-space")).to eq("pre-line")
  end

  it "sits the first visible section flush when an earlier one is hidden" do
    report = create(:report, show: show, kind: "agent", status: "failed", profile_kind: "proxy", seeds: seeds)
    visit show_report_path(show, report)

    expect(page).to have_css("#report_seeds", text: "Index Fund Mornings")
    expect(page).to have_css("#report_summary[hidden]", visible: :all)
    expect(computed_style("#report_seeds", "padding-top")).to eq("0px")
    expect(computed_style("#report_seeds", "border-top-width")).to eq("0px")
  end
end
