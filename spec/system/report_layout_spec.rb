require "rails_helper"

# Checks the compiled report CSS in a real browser: rules only between visible sections, the first visible one
# flush (the :not(... ~ *) selector), a subsection (age and gender) reading as part of the section above it, and
# the summary's lines as At a glance bullets.
RSpec.describe "Report layout" do
  include Warden::Test::Helpers

  let(:user) { create(:user) }
  let(:show) { create(:show, user: user) }
  let(:seeds) { { "entities" => [ { "id" => "q1", "name" => "Index Fund Mornings", "source" => "You listed it" } ], "tags" => [] } }

  before { login_as(user, scope: :user) }

  def computed_style(selector, property)
    evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json})).getPropertyValue(#{property.to_json})")
  end

  it "rules between visible sections, sits the first one flush and shows the summary's lines as bullets" do
    report = create(:report, show: show, kind: "agent", status: "done", profile_kind: "proxy", seeds: seeds,
                             summary: "First line.\nSecond line.",
                             audience: { "tags" => [ { "id" => "t1", "name" => "Personal Finance", "score" => 0.9 } ] },
                             demographics: { "age" => { "25_to_29" => 0.3 }, "gender" => { "male" => 0.1 } })
    visit show_report_path(show, report)

    expect(page).to have_css("#report_seeds", text: "Index Fund Mornings", visible: :all)
    expect(computed_style("#report_summary", "padding-top")).to eq("0px")
    expect(computed_style("#report_summary", "border-top-width")).to eq("0px")
    expect(computed_style("#report_matches", "border-top-width")).to eq("1px")
    expect(computed_style("#report_leans", "border-top-width")).to eq("0px") # part of the audience above it
    expect(computed_style("#report_leans", "padding-top")).to eq("0px")
    expect(page).to have_css("#report_summary .glance > li", text: "First line.")
  end

  it "sits the first visible section flush when an earlier one is hidden" do
    report = create(:report, show: show, kind: "agent", status: "failed", profile_kind: "proxy", seeds: seeds)
    visit show_report_path(show, report)

    expect(page).to have_css("#report_seeds", text: "Index Fund Mornings", visible: :all)
    expect(page).to have_css("#report_summary[hidden]", visible: :all)
    expect(computed_style("#report_how", "padding-top")).to eq("0px")
    expect(computed_style("#report_how", "border-top-width")).to eq("0px")
  end
end
