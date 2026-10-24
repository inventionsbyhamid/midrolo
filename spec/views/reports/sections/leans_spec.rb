require "rails_helper"

RSpec.describe "reports/sections/_leans" do
  let(:demographics) do
    { "age" => { "24_and_younger" => -0.3, "25_to_29" => 0.42, "30_to_34" => 0.1, "35_to_44" => 0.0,
                 "45_to_54" => -0.12, "55_and_older" => -0.5 },
      "gender" => { "male" => 0.2, "female" => -0.2 } }
  end
  let(:report) { create(:report, kind: "agent", status: "done", demographics: demographics) }

  def html = Nokogiri::HTML5.fragment(rendered)

  def render_section = render(partial: "reports/sections/leans", locals: { report: report })

  it "labels the leans as modeled from Qloo taste data, not a headcount" do
    render_section
    expect(html.text.squish).to match(/modeled from Qloo taste data — how people with your listeners' tastes lean, not a headcount/i)
  end

  it "draws a diverging bar per age bucket and gender, centered on zero, with words instead of percentages" do
    render_section
    rows = html.css("[data-lean]")
    expect(rows.map { |row| row.at_css("[data-lean-label]").text.squish })
      .to eq([ "24 and under", "25–29", "30–34", "35–44", "45–54", "55+", "Men", "Women" ])
    expect(rows.map { |row| row["data-lean"] }).to eq(%w[under over over even under under over under])

    over = rows[1] # 25–29, the strongest positive lean
    expect(over.css(".lean-seg-over").size).to be > 0
    expect(over.css(".lean-seg-under")).to be_empty
    under = rows[5] # 55+, the strongest negative lean
    expect(under.css(".lean-seg-under").size).to be > 0
    expect(under.css(".lean-seg-over")).to be_empty
    expect(rows[3].css(".lean-seg-over, .lean-seg-under")).to be_empty # exactly even

    expect(over.text).to include("Over-indexes")
    expect(under.text).to include("Under-indexes")
    expect(html.text).not_to include("%", "0.42")
  end

  it "orders age buckets youngest first whatever order jsonb returns them in" do
    report.update!(demographics: demographics) # jsonb sorts keys by length: "24_and_younger" comes back last
    render(partial: "reports/sections/leans", locals: { report: Report.find(report.id) })
    labels = html.css("[data-lean-label]").map { |label| label.text.squish }
    expect(labels.first(6)).to eq([ "24 and under", "25–29", "30–34", "35–44", "45–54", "55+" ])
  end

  it "skips a group with no data" do
    demographics["gender"] = {}
    render_section
    expect(html.css("[data-lean]").size).to eq(6)
    expect(html.text).not_to include("Gender")
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
