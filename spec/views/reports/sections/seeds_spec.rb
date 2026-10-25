require "rails_helper"

RSpec.describe "reports/sections/_seeds" do
  let(:show) { create(:show, hints: { "comparable_shows" => [ "Acquired" ], "topics" => [ "saas" ] }) }
  let(:seeds) do
    { "entities" => [ { "id" => "q1", "name" => "Index Fund Mornings", "type" => "podcast", "source" => "You listed it" } ],
      "tags" => [ { "id" => "t1", "name" => "Personal Finance", "source" => "Show category: Business" } ],
      "unresolved" => [ "Nonexistent Pod Zzz" ] }
  end
  let(:report) { create(:report, show: show, kind: "agent", status: "done", profile_kind: "proxy", seeds: seeds) }

  def html = Nokogiri::HTML5.fragment(rendered)

  def render_section = render(partial: "reports/sections/seeds", locals: { report: report, read_only: false })

  it "says a proxy profile is built from shows and topics like yours, listing each seed and its source" do
    render_section
    expect(html.text).to include("Built from shows and topics like yours")
    seeds = html.css("[data-seed]").map { |li| [ li.at_css("[data-seed-name]").text, li.at_css("[data-seed-source]").text ] }
    expect(seeds).to eq([ [ "Index Fund Mornings", "You listed it" ], [ "Personal Finance", "Show category: Business" ] ])
    expect(html.text).to include("Nonexistent Pod Zzz")
  end

  it "says a direct profile is built from the show on Qloo" do
    report.update!(profile_kind: "direct")
    render_section
    expect(html.text).to include("Built from your show on Qloo")
    expect(html.text).not_to include("Built from shows and topics like yours")
  end

  context "when the report needs input" do
    before { report.update!(status: "needs_input") }

    it "leaves the form off a read-only report (R78)" do
      render(partial: "reports/sections/seeds", locals: { report: report, read_only: true })
      expect(html.css("form")).to be_empty
    end

    it "asks for comparable shows with an inline form that re-runs the same kind" do
      render_section
      expect(html.text.squish).to include("We need a little more to go on — tell us 2–3 shows your listeners also love.")
      expect(html.text).to include("Nonexistent Pod Zzz")

      form = html.at_css("form[action='#{show_path(show)}']")
      expect(form.at_css("input[name='_method']")["value"]).to eq("patch")
      expect(form.at_css("input[name='rerun']")["value"]).to eq("agent")
      shows = form.css("input[name='show[hints][comparable_shows][]']")
      expect(shows.size).to eq(5)
      expect(shows.first["value"]).to eq("Acquired")
      expect(shows.first["required"]).not_to be_nil
      expect(shows.drop(1).map { |input| input["required"] }.compact).to be_empty
      expect(form.at_css("input[name='report_id']")["value"]).to eq(report.id.to_s)
      expect(form.css("input[name='show[hints][topics][]']").first["value"]).to eq("saas")
      expect(form.css("input[type='submit'], button[type='submit']")).to be_present
    end

    it "still asks when no seeds were saved at all" do
      report.update!(seeds: nil)
      render_section
      expect(html.at_css("form[action='#{show_path(show)}']")).to be_present
      expect(html.css(".skeleton")).to be_empty
    end
  end

  it "shows a skeleton while the run is going" do
    report.update!(status: "running", seeds: nil)
    render_section
    expect(html.css(".skeleton")).to be_present
  end
end
