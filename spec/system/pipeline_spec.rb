require "rails_helper"

# The pipeline form on a match card in a real browser. The status select saves on change (status_form_controller);
# the Turbo Stream reply morphs the form in place; focus stays on the select and an open notes panel stays open.
RSpec.describe "Sponsor pipeline" do
  include Warden::Test::Helpers

  let(:user) { create(:user, :subscribed) } # the pipeline is a Creator feature (R45)
  let(:podcast) { create(:show, user: user, title: "The Founder's Ledger") } # not :show, which the failure screenshot helper calls
  let(:report) { create(:report, show: podcast, kind: "agent", status: "done") }
  let!(:brand_match) { create(:sponsor_match, report: report, name: "Fieldnote Coffee") }

  before { login_as(user, scope: :user) }

  def active_element_id = evaluate_script("document.activeElement && document.activeElement.id")

  def horizontal_overflow = evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")

  it "saves the status on change, then notes and a follow-up, and lists the brand in the pipeline" do
    visit show_report_path(podcast, report)

    status = find_field("Pipeline status for Fieldnote Coffee")
    execute_script("arguments[0].focus()", status) # as a keyboard user tabbing to it
    status.select("Pitched")
    expect(page).to have_css("[role='status']", text: "Saved", wait: 10)
    expect(brand_match.reload.status).to eq("pitched")
    expect(active_element_id).to eq(status[:id]) # focus stays on the select through the save

    find("summary", text: "Notes & follow up").click
    fill_in "Notes", with: "Emailed Sam at partnerships"
    fill_in "Follow up date", with: Date.current
    click_button "Save notes"

    expect(page).to have_css("details[open] summary", text: "Follow up today", wait: 10)
    expect(page).to have_css("summary", text: "Note")
    expect(brand_match.reload).to have_attributes(notes: "Emailed Sam at partnerships", follow_up_on: Date.current)

    click_link "Pipeline", match: :first
    within("#stage_pitched") do
      expect(page).to have_text("Fieldnote Coffee")
      expect(page).to have_text("Emailed Sam at partnerships")
      expect(page).to have_text("Due today")
    end
  end

  it "confirms every save with a fresh, animated Saved in the same live region" do
    visit show_report_path(podcast, report)
    status = find_field("Pipeline status for Fieldnote Coffee")
    region_id = find("[role='status']", visible: :all)[:id]

    status.select("Saved")
    expect(page).to have_css(".status-saved-msg", text: "Saved", wait: 10)
    execute_script("document.querySelector('.status-saved-msg').dataset.earlier = 'yes'")
    execute_script("document.getElementById(#{region_id.to_json}).sameRegion = true") # a property: a morph would drop an attribute

    find_field("Pipeline status for Fieldnote Coffee").select("Pitched")
    expect(page).to have_css(".status-saved-msg:not([data-earlier])", text: "Saved", wait: 10)
    expect(evaluate_script("document.getElementById(#{region_id.to_json}).sameRegion")).to be(true) # the region itself stayed
    expect(evaluate_script("document.querySelector('.status-saved-msg').getAnimations().length")).to eq(1)
    expect(brand_match.reload.status).to eq("pitched")
  end

  it "shows a validation error inline without losing the panel" do
    visit show_report_path(podcast, report)

    find("summary", text: "Notes & follow up").click
    fill_in "Notes", with: "x" * SponsorMatch::NOTES_LIMIT
    # The browser enforces maxlength while typing; a crafted value past it still gets a friendly error.
    execute_script("document.querySelector('textarea').removeAttribute('maxlength')")
    find_field("Notes").send_keys("y")
    click_button "Save notes"

    # The round trip can outlast Capybara's 2-second default while the whole suite runs.
    expect(page).to have_css("[role='alert']", text: "Notes can be at most #{SponsorMatch::NOTES_LIMIT} characters", wait: 10)
    expect(page).to have_css("details[open] textarea[aria-invalid='true']")
    expect(brand_match.reload.notes).to be_nil
  end

  it "fits a phone screen, on the report and the pipeline" do
    brand_match.update!(status: "pitched", notes: "Emailed Sam " * 20, follow_up_on: Date.current)
    page.driver.resize(375, 812)

    visit show_report_path(podcast, report)
    find("summary", text: "Notes & follow up").click
    expect(page).to have_field("Notes")
    expect(horizontal_overflow).to eq(0)

    visit pipeline_path
    expect(page).to have_css("#stage_pitched", text: "Fieldnote Coffee")
    expect(horizontal_overflow).to eq(0)
  end
end
