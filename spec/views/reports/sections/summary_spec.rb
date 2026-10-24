require "rails_helper"

RSpec.describe "reports/sections/_summary" do
  let(:report) { create(:report, kind: "agent", status: "done", summary: "Money-minded listeners who love slow travel.") }

  def html = Nokogiri::HTML5.fragment(rendered)

  def render_section = render(partial: "reports/sections/summary", locals: { report: report })

  it "leads with the summary" do
    render_section
    expect(html.text).to include("Money-minded listeners who love slow travel.")
  end

  it "shows the upgrade card on a snapshot" do
    report.update!(kind: "snapshot", summary: nil)
    render_section
    expect(html.text.squish).to include("This is your free Snapshot. Upgrade for the full agent report: reasons, proven sponsors, pitch emails.")
    expect(html.css(".skeleton")).to be_empty
  end

  it "shows a skeleton while the summary is still coming" do
    report.update!(status: "running", summary: nil)
    render_section
    expect(html.css(".skeleton")).to be_present
  end

  it "is hidden on a finished full report without a summary" do
    report.update!(status: "failed", summary: nil)
    render_section
    expect(html.at_css("#report_summary")["hidden"]).not_to be_nil
  end
end
