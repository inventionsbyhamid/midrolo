require "rails_helper"

# The report's reading order (R99): At a glance, matches, the audience with its age and gender, where they are, then
# How we built this collapsed at the bottom. Only a live run has a steps rail.
RSpec.describe "reports/_body" do
  let(:owner) { create(:user, judge: true) }
  let(:report) do
    create(:report, show: create(:show, user: owner), kind: "agent", status: "done", profile_kind: "direct",
                    summary: "Founders who love finance tools.",
                    seeds: { "entities" => [ { "id" => "q1", "name" => "Index Fund Mornings", "source" => "You listed it" } ], "tags" => [] },
                    audience: { "tags" => [ { "id" => "t1", "name" => "Personal Finance", "score" => 0.9 } ] },
                    demographics: { "age" => { "25_to_29" => 0.3 }, "gender" => { "male" => 0.1 } },
                    heatmap: { "location" => "US", "country" => "US", "points" => [ { "lat" => 30.3, "lng" => -97.7, "affinity" => 1.0, "label" => "Austin" } ] })
  end

  before do
    create(:sponsor_match, report: report, name: "Fieldnote Coffee")
    create(:agent_step, report: report, label: "Reading your last 15 episodes…", status: "ok")
  end

  def html = Nokogiri::HTML5.fragment(rendered)

  before { allow(view).to receive(:user_signed_in?).and_return(false) }

  def render_body(read_only: false) = render(partial: "reports/body", locals: { report: report, read_only: read_only })

  def section_ids = html.css(".report-sections > section:not([hidden])").map { |section| section["id"] }

  it "reads top to bottom: At a glance, matches, audience, age and gender, where they are, How we built this" do
    render_body
    expect(section_ids).to eq(%w[report_summary report_matches report_audience report_leans report_map report_how])
    expect(html.css(".report-sections > section > header > h2").map(&:text))
      .to eq([ "At a glance", "Sponsor matches", "Your audience", "Where they are", "How we built this" ])
  end

  it "has no steps rail on a finished report: the seeds, steps and method wait in How we built this, collapsed" do
    render_body
    expect(html.css("aside, [data-controller~='responsive-details']")).to be_empty

    how = html.at_css("#report_how details")
    expect(how["open"]).to be_nil
    expect(how.at_css("summary").text.squish).to eq("Show the taste profile, steps and method")
    expect(how.at_css("#report_seeds").text).to include("Index Fund Mornings")
    expect(how.at_css("#agent_steps_report_#{report.public_id}").text).to include("Reading your last 15 episodes…")
    expect(how.css("dt").map(&:text)).to eq([ "Qloo taste data", "Proven sponsors", "Midrolo fit score" ])
  end

  it "keeps the live rail while the report runs, with each Turbo Stream target on the page once" do
    report.update!(status: "running")
    render_body

    rail = html.at_css("aside details[data-controller~='responsive-details']")
    expect(rail["open"]).not_to be_nil
    expect(rail.at_css("#agent_steps_report_#{report.public_id}")).to be_present
    expect(html.at_css("#report_how #report_seeds")).to be_present
    ids = html.css("[id]").map { |node| node["id"] }
    expect(ids).to eq(ids.uniq)
  end

  it "leads with the ask when the report needs input" do
    report.update!(status: "needs_input")
    render_body
    expect(section_ids.first).to eq("report_seeds")
    expect(html.at_css("#report_seeds h2").text).to eq("Taste profile")
    expect(html.css("#report_seeds").size).to eq(1)
  end

  it "keeps the headings in order: an h2 per section, h3 inside" do
    render_body
    levels = html.css("h2, h3").map { |heading| heading.name[1].to_i }
    expect(levels.first).to eq(2)
    expect(levels.each_cons(2).select { |a, b| b > a + 1 }).to be_empty
  end

  it "speaks of the method without owner words on a public sample (R78)" do
    render_body(read_only: true)
    expect(html.at_css("#report_how .method-list").text).not_to match(/\byour\b/i)
  end
end
