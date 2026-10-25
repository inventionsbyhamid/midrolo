require "rails_helper"

RSpec.describe "reports/sections/_leans" do
  let(:demographics) do
    { "age" => { "24_and_younger" => -0.3, "25_to_29" => 0.42, "30_to_34" => 0.1, "35_to_44" => 0.0,
                 "45_to_54" => -0.12, "55_and_older" => -0.5 },
      "gender" => { "male" => 0.2, "female" => -0.2 } }
  end
  let(:report) { create(:report, kind: "agent", status: "done", demographics: demographics) }

  def html = Nokogiri::HTML5.fragment(rendered)

  def render_section = render(partial: "reports/sections/leans", locals: { report: report, read_only: false })

  it "sits under the audience as Age and gender, labelled modeled from Qloo taste data, not measured" do
    render_section
    expect(html.at_css("#report_leans h3").text).to eq("Age and gender")
    expect(html.at_css(".leans-note").text).to eq("Modeled from Qloo taste data, not measured.")
  end

  it "draws age as one short chart of at most 6 bars around the average, in words, never percentages" do
    render_section
    bars = html.css(".age-bars [data-lean]")
    expect(bars.size).to eq(6)
    expect(bars.map { |bar| bar.at_css("[data-lean-label]").text.squish })
      .to eq([ "24 and under", "25 to 29", "30 to 34", "35 to 44", "45 to 54", "55+" ])
    expect(bars.map { |bar| bar["data-lean"] }).to eq(%w[under over over even under under])
    expect(bars[1].at_css(".sr-only").text).to include("Well above average")
    expect(bars[5].at_css(".sr-only").text).to include("Well below average")
    expect(html.text).not_to include("%", "0.42", "index")
  end

  it "puts gender on one line" do
    render_section
    expect(html.at_css("[data-gender-line]").text.squish).to eq("Gender Leans a little toward men")
    expect(html.css("[data-lean]").size).to eq(6) # no bars for gender
  end

  it "orders age buckets youngest first whatever order jsonb returns them in" do
    report.update!(demographics: demographics) # jsonb sorts keys by length: "24_and_younger" comes back last
    render(partial: "reports/sections/leans", locals: { report: Report.find(report.id), read_only: false })
    labels = html.css("[data-lean-label]").map { |label| label.text.squish }
    expect(labels).to eq([ "24 and under", "25 to 29", "30 to 34", "35 to 44", "45 to 54", "55+" ])
  end

  it "skips a group with no data" do
    demographics["gender"] = {}
    render_section
    expect(html.css("[data-lean]").size).to eq(6)
    expect(html.css("[data-gender-line]")).to be_empty
  end

  it "shows a skeleton while the run is going" do
    report.update!(status: "running", demographics: nil)
    render_section
    expect(html.css(".skeleton")).to be_present
  end

  it "is hidden on a finished report without leans (a snapshot)" do
    report.update!(kind: "snapshot", demographics: nil)
    render_section
    expect(html.at_css("#report_leans")["hidden"]).not_to be_nil
  end
end
