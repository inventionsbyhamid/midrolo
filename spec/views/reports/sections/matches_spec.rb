require "rails_helper"

RSpec.describe "reports/sections/_matches" do
  let(:report) { create(:report, kind: "agent", status: "done") }

  def html = Nokogiri::HTML5.fragment(rendered)

  def render_section = render(partial: "reports/sections/matches", locals: { report: report })

  def limit_visible_to(count)
    allow(Entitlements).to receive(:for).and_return(instance_double(Entitlements::Plan, visible_matches_limit: count))
  end

  def proven(*shows, count: shows.size)
    items = shows.map.with_index { |show, i| { "show" => show, "episode_title" => "Ep #{i}", "published_at" => "2026-10-#{12 - i}T09:00:00Z" } }
    { "shared_tags" => [ "Investing" ], "proven" => { "items" => items, "count" => count } }
  end

  context "with 50 matches and a plan that shows 5" do
    before do
      (1..50).each do |i|
        create(:sponsor_match, report: report, position: i, name: "Brand #{format('%02d', i)}", reason: "Reason for brand #{i}.",
                               website: "https://brand#{i}.example.com", image_url: "https://img.example.com/#{i}.png",
                               tier: %w[easy_yes realistic long_shot][i % 3], fit_score: 100 - i, evidence: proven("Show #{i}"))
      end
      limit_visible_to(5)
      render_section
    end

    it "renders the top 5 in full and the rest blurred behind an unlock overlay" do
      expect(html.css("[data-filter-target='item']").size).to eq(5)
      expect(html.css("[data-locked-match]").size).to eq(45)
      unlock = html.at_css("a[href='/pricing']")
      expect(unlock.text.squish).to eq("Unlock 45 more matches")
    end

    it "puts no hidden brand's name, reason, image, website or evidence in the HTML" do
      expect(rendered).to include("Brand 05", "Reason for brand 5.", "brand5.example.com")
      (6..50).each do |i|
        expect(rendered).not_to include("Brand #{format('%02d', i)}")
        expect(rendered).not_to include("Reason for brand #{i}.")
        expect(rendered).not_to include("brand#{i}.example.com", "img.example.com/#{i}.png")
        expect(rendered).not_to include("Show #{i}<", "Show #{i} ")
      end
    end

    it "shows only a silhouette, the tier and a fit bucket on a blurred card" do
      card = html.css("[data-locked-match]").first # match 6: fit 94, easy yes
      expect(card.text.squish).to eq("•• Easy yes High fit")
      expect(card.css("img, a")).to be_empty
      expect(html.css("[data-locked-match]").last.text.squish).to eq("•• Long shot Good fit") # match 50: fit 50
    end
  end

  context "with a fully evidenced match" do
    before do
      create(:sponsor_match, report: report, name: "Fieldnote Coffee", category: "Coffee", fit_score: 91, tier: "easy_yes",
                             affinity: 0.82, reason: "Your audience shares 6 taste signals with Fieldnote fans.",
                             website: "https://fieldnote.example.com/shop", image_url: nil,
                             evidence: { "shared_tags" => %w[A B C D E F],
                                         "proven" => proven("Harbor Lights", "Tide Tables", count: 4)["proven"] })
      render_section
    end

    let(:card) { html.at_css("[data-filter-target='item']") }

    it "shows logo initials, name, category, fit meter, tier and reason" do
      expect(card.at_css("h3").text.squish).to eq("Fieldnote Coffee")
      expect(card.text).to include("FC", "Coffee", "Easy yes", "Your audience shares 6 taste signals with Fieldnote fans.")
      meter = card.at_css("[role='meter']")
      expect(meter["aria-valuenow"]).to eq("91")
      expect(meter.text).to include("91")
    end

    it "shows the evidence chips with the newest proven sponsorships and a count of the rest" do
      chips = card.css(".chip").map { |chip| chip.text.squish }
      expect(chips).to eq([ "Shares 6 taste tags", "Affinity 0.82", "Sponsored Harbor Lights · Oct 12",
                            "Sponsored Tide Tables · Oct 11", "+2 more" ])
      expect(card.at_css(".chip em").text).to eq("Harbor Lights")
    end

    it "links the website safely" do
      link = card.at_css("a[href='https://fieldnote.example.com/shop']")
      expect(link.text).to include("fieldnote.example.com")
      expect(link["rel"]).to include("noopener")
      expect(link["target"]).to eq("_blank")
    end

    it "carries the filter data and the placeholder actions" do
      expect(card["data-category"]).to eq("Coffee")
      expect(card["data-tier"]).to eq("easy_yes")
      expect(card["data-proven"]).to eq("true")
      expect(card["data-fit"]).to eq("91")

      pitch = card.at_xpath(".//button[contains(., 'Write my pitch')]")
      expect(pitch["disabled"]).not_to be_nil
      expect(card.text).to include("Coming in the next step")
      expect(card.at_css("select")["disabled"]).not_to be_nil
    end
  end

  it "labels tiers in plain words" do
    { "easy_yes" => "Easy yes", "realistic" => "Realistic", "long_shot" => "Long shot" }.each_with_index do |(tier, _), i|
      create(:sponsor_match, report: report, tier: tier, position: i + 1)
    end
    render_section
    badges = html.css("[data-filter-target='item'] .badge").map(&:text)
    expect(badges).to eq([ "Easy yes", "Realistic", "Long shot" ])
  end

  it "offers category, tier and proven filters and a sort, all unpressed" do
    create(:sponsor_match, report: report, category: "Finance", position: 1)
    create(:sponsor_match, report: report, category: "Coffee", position: 2, evidence: proven("Harbor Lights"))
    create(:sponsor_match, report: report, category: "Finance", position: 3)
    render_section

    chips = html.css("button[aria-pressed]")
    expect(chips.map { |c| c.text.squish }).to eq([ "Easy yes", "Realistic", "Long shot", "Proven sponsors only", "Finance", "Coffee" ])
    expect(chips.map { |c| c["aria-pressed"] }.uniq).to eq([ "false" ])
    expect(html.css("select[data-filter-target='sort'] option").map(&:text)).to eq([ "Best fit", "Easiest to land" ])
    expect(html.css("[data-filter-target='item']").map { |c| c["data-proven"] }).to eq(%w[false true false])
  end

  it "leaves out the reason on a snapshot match" do
    report.update!(kind: "snapshot")
    create(:sponsor_match, report: report, reason: nil)
    render_section
    expect(html.css("[data-match-reason]")).to be_empty
  end

  it "says so when a finished report has no matches" do
    render_section
    expect(html.text).to include("No matches yet.")
    expect(html.css(".skeleton")).to be_empty
  end

  it "shows a skeleton while matches are still coming" do
    report.update!(status: "running")
    render_section
    expect(html.css(".skeleton")).to be_present
  end

  it "hides the section on a failed report with no matches" do
    report.update!(status: "failed")
    render_section
    expect(html.at_css("#report_matches")["hidden"]).not_to be_nil
  end
end
