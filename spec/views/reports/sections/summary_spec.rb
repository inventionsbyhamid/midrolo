require "rails_helper"

# At a glance (R99): at most three bullets under the header: who listens, the best fits and the next step.
RSpec.describe "reports/sections/_summary" do
  let(:owner) { create(:user, judge: true) }
  let(:report) do
    create(:report, show: create(:show, user: owner), kind: "agent", status: "done",
                    summary: "Money minded founders who love slow travel.\nStart with the budgeting apps.\nBuilt from shows like yours.")
  end

  def html = Nokogiri::HTML5.fragment(rendered)

  def render_section(read_only: false) = render(partial: "reports/sections/summary", locals: { report: report, read_only: read_only })

  def bullets = html.css("#report_summary ul.glance > li")

  def bullet(label) = bullets.find { |li| li.at_css(".glance-label").text == label }

  # The sample's call to action reads the sign in state (PagesHelper#snapshot_start_path).
  before { allow(view).to receive(:user_signed_in?).and_return(false) }

  def add_matches(count)
    (1..count).map { |i| create(:sponsor_match, report: report, position: i, name: "Brand #{i}") }
  end

  def slot(label) = bullet(label)&.at_css(".glance-body")&.text&.squish

  def notes = html.css("#report_summary .glance-notes p").map { |p| p.text.squish }

  it "shows At a glance with at most 3 bullets: who listens, the best fits and the next step" do
    add_matches(5)
    render_section

    expect(html.at_css("#report_summary h2").text).to eq("At a glance")
    expect(bullets.size).to eq(3)
    expect(bullets.map { |li| li.at_css(".glance-label").text }).to eq([ "Who listens", "Best fits", "Next step" ])
    expect(slot("Who listens")).to eq("Money minded founders who love slow travel.")
    expect(slot("Best fits")).to eq("Brand 1, Brand 2 and Brand 3") # data only, never a model bullet (R104)
    expect(bullet("Best fits").css("a").map(&:text)).to eq([ "Brand 1", "Brand 2", "Brand 3" ])
    expect(notes).to eq([ "Start with the budgeting apps.", "Built from shows like yours." ]) # the rest, unlabelled
  end

  it "names the visible top 3 by fit score as the best fits (R104)" do
    create(:sponsor_match, report: report, position: 1, name: "Brand Low", fit_score: 60)
    create(:sponsor_match, report: report, position: 2, name: "Brand High", fit_score: 95)
    create(:sponsor_match, report: report, position: 3, name: "Brand Mid", fit_score: 80)
    create(:sponsor_match, report: report, position: 4, name: "Brand Least", fit_score: 50)
    render_section
    expect(slot("Best fits")).to eq("Brand High, Brand Mid and Brand Low")
  end

  context "with an older prose summary (R103)" do
    let(:prose) do
      "Built from your show's own Qloo profile. Your listeners' tastes center on Healthy Eating, Education, and Fitness. " \
        "We ranked 50 sponsors: 32 easy yes, 17 realistic, and 1 long shot. Start with Dr. Squatch."
    end

    before do
      report.update!(summary: prose, audience: { "tags" => [ { "name" => "Healthy Eating", "score" => 0.9 }, { "name" => "Fitness", "score" => 0.8 } ] })
      add_matches(3)
      render_section
    end

    it "keeps its sentences out of the labelled lines: who listens comes from the data" do
      expect(slot("Who listens")).to eq("This audience leans toward Healthy Eating and Fitness.")
      expect(slot("Best fits")).to eq("Brand 1, Brand 2 and Brand 3")
      bullets.each { |li| expect(li.text).not_to include("Your listeners' tastes", "We ranked", "Built from") }
    end

    it "shows its sentences as plain text, without the leading Built from" do
      expect(notes).to eq([ "Your listeners' tastes center on Healthy Eating, Education, and Fitness. " \
                            "We ranked 50 sponsors: 32 easy yes, 17 realistic, and 1 long shot. Start with Dr. Squatch." ])
    end
  end

  it "leaves out who listens when older prose comes with no interests to speak from" do
    report.update!(summary: "Built from shows like yours. #{'Your listeners love finance tools and slow travel. ' * 3}")
    add_matches(3)
    render_section
    expect(bullets.map { |li| li.at_css(".glance-label").text }).to eq([ "Best fits", "Next step" ])
  end

  it "links each best fit to its row" do
    first = add_matches(3).first
    render_section
    expect(bullets[1].at_css("a")["href"]).to eq("#sponsor_match_#{first.id}")
  end

  it "points the owner at their first pitch" do
    matches = add_matches(3)
    render_section
    link = bullets[2].at_css("a")
    expect(link.text).to eq("Write your first pitch to Brand 1")
    expect(link["href"]).to eq("#sponsor_match_#{matches.first.id}")
  end

  it "points the owner at the next brand not pitched yet" do
    matches = add_matches(3)
    Pitch.create!(sponsor_match: matches.first, status: "done")
    render_section
    expect(bullets[2].at_css("a").text).to eq("Write your next pitch to Brand 2")
  end

  it "asks a stranger on a sample to get their own Snapshot, with no owner controls (R78)" do
    add_matches(3)
    render_section(read_only: true)
    expect(bullets[2].text.squish).to include("Get your own Snapshot")
    expect(html.css("form")).to be_empty
    expect(html.text).not_to include("pitch")
  end

  it "speaks of a Snapshot's audience from its top interests and offers the full report" do
    report.update!(kind: "snapshot", summary: nil,
                   audience: { "tags" => [ { "name" => "Personal Finance", "score" => 0.9 }, { "name" => "Slow Travel", "score" => 0.8 },
                                           { "name" => "Coffee", "score" => 0.7 }, { "name" => "Cycling", "score" => 0.6 } ] })
    add_matches(2)
    render_section

    expect(bullets.size).to eq(3)
    expect(bullets[0].text).to include("This audience leans toward Personal Finance, Slow Travel and Coffee.")
    expect(bullets[2].text.squish).to include("This is your free Snapshot. Run the full report for reasons, proven sponsors and pitch emails.")
    form = bullets[2].at_css("form[action='#{show_reports_path(report.show, kind: 'agent')}']")
    expect(form.at_css("button").text).to eq("Run full report")
  end

  it "names only visible brands among the best fits of a Snapshot (R43)" do
    report.update!(kind: "snapshot", summary: nil)
    add_matches(4)
    allow(Entitlements).to receive(:for).and_return(instance_double(Entitlements::Plan, visible_matches_limit: 1))
    render_section

    expect(bullet("Best fits").css("a").map(&:text)).to eq([ "Brand 1" ])
    expect(rendered).not_to include("Brand 2", "Brand 3", "Brand 4")
  end

  it "keeps the upsell off a read-only Snapshot (R78)" do
    report.update!(kind: "snapshot")
    render_section(read_only: true)

    expect(html.text).not_to include("This is your free Snapshot")
    expect(html.css("form, button")).to be_empty
  end

  it "keeps the upsell off a snapshot that needs input" do
    report.update!(kind: "snapshot", status: "needs_input", summary: nil)
    render_section
    expect(html.text).not_to include("This is your free Snapshot")
    expect(html.css("form, button")).to be_empty
    expect(html.at_css("#report_summary")["hidden"]).not_to be_nil
  end

  it "keeps the upsell off a failed snapshot" do
    report.update!(kind: "snapshot", status: "failed", summary: nil)
    render_section
    expect(html.text).not_to include("This is your free Snapshot")
    expect(html.at_css("#report_summary")["hidden"]).not_to be_nil
  end

  it "shows a skeleton while the summary is still coming" do
    report.update!(status: "running", summary: nil)
    render_section
    expect(html.css(".skeleton")).to be_present
  end
end
