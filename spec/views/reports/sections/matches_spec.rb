require "rails_helper"

RSpec.describe "reports/sections/_matches" do
  let(:report) { create(:report, kind: "agent", status: "done") }

  def html = Nokogiri::HTML5.fragment(rendered)

  def render_section = render(partial: "reports/sections/matches", locals: { report: report })

  def limit_visible_to(count, pipeline: true)
    allow(Entitlements).to receive(:for)
      .and_return(instance_double(Entitlements::Plan, visible_matches_limit: count, pipeline?: pipeline))
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
                               tier: %w[easy_yes realistic long_shot][i % 3], fit_score: 100 - i, evidence: proven("Show #{i}"),
                               category: i == 7 ? "Zz Locked Only Category" : %w[Finance Coffee][i % 2],
                               brand_description: "Qloo blurb for brand #{i}.")
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
      expect(rendered).not_to include("Zz Locked Only Category")
      expect(rendered).not_to include("Qloo blurb") # R52: the description feeds the pitch writer only, never a card
      expect(html.css("button[data-group='category']").map { |chip| chip["data-value"] }).to contain_exactly("Finance", "Coffee")
    end

    it "shows only a silhouette, the tier and a fit bucket on a blurred card" do
      card = html.css("[data-locked-match]").first # match 6: fit 94, easy yes
      expect(card.text.squish).to eq("•• Easy yes High fit")
      expect(card.css("img, a, form, select")).to be_empty
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

    it "carries the filter data" do
      expect(card["data-category"]).to eq("Coffee")
      expect(card["data-tier"]).to eq("easy_yes")
      expect(card["data-proven"]).to eq("true")
      expect(card["data-fit"]).to eq("91")
    end

    it "has a Write my pitch button that posts to the match's pitch" do
      match = report.sponsor_matches.first
      form = card.at_xpath(".//form[.//button[contains(., 'Write my pitch')]]")
      expect(form["action"]).to eq("/sponsor_matches/#{match.id}/pitch")
      expect(form["method"]).to eq("post")
      expect(form.at_css("button")["disabled"]).to be_nil
      expect(card.text).not_to include("coming soon")
    end

    it "offers a live pipeline form: a labelled status select that saves on change, notes and a follow-up date" do
      match = report.sponsor_matches.first
      form = card.at_css("form##{ActionView::RecordIdentifier.dom_id(match, :status_form)}")
      expect(form["action"]).to eq("/sponsor_matches/#{match.id}")
      expect(form.at_css("input[name='_method']")["value"]).to eq("patch")
      expect(form["data-controller"]).to eq("status-form")

      select = form.at_css("select[name='sponsor_match[status]']")
      expect(select["disabled"]).to be_nil
      expect(select["data-action"]).to eq("status-form#submit")
      expect(select.css("option").map(&:text)).to eq(%w[Suggested Saved Pitched Replied Won Lost])
      expect(form.at_css("label[for='#{select['id']}']").text.squish).to eq("Pipeline status for Fieldnote Coffee")
      expect(form.at_css("noscript").inner_html).to include("Save")
      expect(form.at_css("[role='status']")).to be_present

      details = form.at_css("details")
      expect(details["open"]).to be_nil
      expect(details.at_css("summary").text.squish).to eq("Notes & follow-up")
      %w[notes follow_up_on].each do |field|
        input = details.at_css("[name='sponsor_match[#{field}]']")
        expect(details.at_css("label[for='#{input['id']}']")).to be_present
      end
      expect(details.at_css("textarea")["maxlength"]).to eq(SponsorMatch::NOTES_LIMIT.to_s)
      expect(details.at_css("input[type='date']")).to be_present
    end
  end

  context "with notes and a follow-up date set" do
    before do
      travel_to(Date.new(2026, 10, 25))
      create(:sponsor_match, report: report, status: "pitched", notes: "Emailed Sam", follow_up_on: Date.new(2026, 10, 25))
      render_section
    end

    after { travel_back }

    it "flags both on the closed notes panel" do
      summary = html.at_css("details summary")
      expect(summary.text.squish).to eq("Notes & follow-up Note Follow up today")
      expect(html.at_css("select option[selected]")["value"]).to eq("pitched")
    end
  end

  it "gives every form control on the page a unique id" do
    create_list(:sponsor_match, 3, report: report)
    render_section
    ids = html.css("[id]").map { |node| node["id"] }
    expect(ids).to eq(ids.uniq)
    expect(html.css("form[data-controller='status-form']").size).to eq(3)
  end

  describe "brands tracked on a newer report (R48)" do
    it "shows the newer copy's status read-only with a link to it, and keeps the other brands editable" do
      create(:sponsor_match, report: report, brand_entity_id: "b1", name: "Fieldnote Coffee", position: 1)
      create(:sponsor_match, report: report, brand_entity_id: "b2", name: "Only Here", position: 2)
      newer_report = create(:report, show: report.show, kind: "agent", status: "done")
      newer = create(:sponsor_match, report: newer_report, brand_entity_id: "b1", status: "pitched")
      render_section

      superseded, current = html.css("[data-filter-target='item']")
      # The pipeline form is gone; the pitch button stays on any visible card (R51).
      expect(superseded.css("form:not([action$='/pitch']), select, textarea")).to be_empty
      expect(superseded.at_xpath(".//button[contains(., 'Write my pitch')]")).to be_present
      state = superseded.at_css("[data-superseded]")
      expect(state.text.squish).to eq("Pipeline Pitched Tracked on your latest report →")
      href = show_report_path(newer_report.show, newer_report, anchor: ActionView::RecordIdentifier.dom_id(newer))
      expect(state.at_css("a")["href"]).to eq(href)
      expect(current.at_css("form select[name='sponsor_match[status]']")).to be_present
    end

    it "keeps a running re-run's cards editable before carry-forward reaches them" do
      create(:sponsor_match, report: report, brand_entity_id: "b1", status: "pitched")
      running = create(:report, show: report.show, kind: "agent", status: "running")
      create(:sponsor_match, report: running, brand_entity_id: "b1")
      render(partial: "reports/sections/matches", locals: { report: running })

      expect(html.at_css("[data-filter-target='item'] form select")).to be_present
      expect(html.at_css("[data-superseded]")).to be_nil
    end
  end

  it "points to the Creator plan instead of the form when the plan has no pipeline (R45)" do
    create(:sponsor_match, report: report)
    limit_visible_to(50, pipeline: false)
    render_section
    card = html.at_css("[data-filter-target='item']")
    expect(card.css("form:not([action$='/pitch']), select, textarea")).to be_empty
    link = card.at_css("a[href='/pricing']")
    expect(link.text.squish).to eq("Track this brand in your pipeline — Creator plan")
  end

  it "opens the written pitch instead of writing another once the match has one" do
    match = create(:sponsor_match, report: report)
    Pitch.create!(sponsor_match: match, status: "done")
    render_section
    card = html.at_css("[data-filter-target='item']")
    link = card.at_css("a[href='/sponsor_matches/#{match.id}/pitch'][data-turbo-stream='true']")
    expect(link.text.squish).to eq("Open pitch")
    expect(card.at_xpath(".//button[contains(., 'Write my pitch')]")).to be_nil
  end

  it "leaves the tier line out of the unlock prompt when no locked tier is known" do
    create(:sponsor_match, report: report, position: 1)
    create(:sponsor_match, report: report, position: 2, tier: nil)
    create(:sponsor_match, report: report, position: 3, tier: "mystery")
    limit_visible_to(1)
    render_section
    expect(html.text.squish).to include("Unlock 2 more matches")
    expect(html.text).not_to include("Includes")
    expect(html.css("[data-locked-match] .badge")).to be_empty
  end

  it "names only the known tiers in the unlock prompt" do
    create(:sponsor_match, report: report, position: 1)
    create(:sponsor_match, report: report, position: 2, tier: "long_shot")
    create(:sponsor_match, report: report, position: 3, tier: nil)
    limit_visible_to(1)
    render_section
    expect(html.text.squish).to include("Includes 1 long shot brand, each with its reason and evidence.")
  end

  it "falls back to initials through a Stimulus action, with no inline handler" do
    create(:sponsor_match, report: report, image_url: "https://img.example.com/logo.png")
    render_section
    img = html.at_css("[data-filter-target='item'] img")
    expect(img["onerror"]).to be_nil
    expect(img["data-action"]).to eq("error->logo#fallback")
    expect(img.ancestors("[data-controller~='logo']")).to be_present
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
