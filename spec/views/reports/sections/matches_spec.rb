require "rails_helper"

RSpec.describe "reports/sections/_matches" do
  # A judge owner has Pro features, the pipeline among them.
  let(:owner) { create(:user, judge: true) }
  let(:report) { create(:report, show: create(:show, user: owner), kind: "agent", status: "done") }

  def html = Nokogiri::HTML5.fragment(rendered)

  def render_section = render(partial: "reports/sections/matches", locals: { report: report, read_only: false })

  def limit_visible_to(count, pipeline: true)
    allow(Entitlements).to receive(:for)
      .and_return(instance_double(Entitlements::Plan, visible_matches_limit: count, pipeline?: pipeline))
  end

  def proven(*shows, count: shows.size)
    items = shows.map.with_index { |show, i| { "show" => show, "episode_title" => "Ep #{i}", "published_at" => "2026-10-#{12 - i}T09:00:00Z" } }
    { "shared_tags" => [ "Investing" ], "proven" => { "items" => items, "count" => count } }
  end

  context "with 50 matches on a Snapshot and a plan that shows 12" do
    before do
      report.update!(kind: "snapshot")
      (1..50).each do |i|
        create(:sponsor_match, report: report, position: i, name: "Brand #{format('%02d', i)}", reason: "Reason for brand #{i}.",
                               website: "https://brand#{i}.example.com", image_url: "https://img.example.com/#{i}.png",
                               tier: %w[easy_yes realistic long_shot][i % 3], fit_score: 100 - i, evidence: proven("Show #{i}"),
                               category: i == 20 ? "Zz Locked Only Category" : %w[Finance Coffee][i % 2],
                               brand_description: "Qloo blurb for brand #{i}.")
      end
      limit_visible_to(12)
      render_section
    end

    it "renders the 12 visible matches in full and a few locked rows behind an unlock overlay" do
      expect(html.css("[data-filter-target='item']").size).to eq(12)
      expect(html.css("[data-locked-match]").size).to eq(10) # shapes only; the count is in the prompt
      unlock = html.at_css("a[href='/pricing']")
      expect(unlock.text.squish).to eq("Unlock 38 more matches")
      # The page's one primary action is its next step, in At a glance (R111).
      expect(unlock["class"].split).to include("btn-secondary")
      expect(unlock["class"].split).not_to include("btn-primary")
    end

    it "puts no hidden brand's name, reason, image, website or evidence in the HTML (R43)" do
      expect(rendered).to include("Brand 12", "Reason for brand 12.")
      (13..50).each do |i|
        expect(rendered).not_to include("Brand #{format('%02d', i)}")
        expect(rendered).not_to include("Reason for brand #{i}.")
        expect(rendered).not_to include("brand#{i}.example.com", "img.example.com/#{i}.png")
        expect(rendered).not_to include("Show #{i}<", "Show #{i} ")
      end
      expect(rendered).not_to include("Zz Locked Only Category")
      expect(rendered).not_to include("Qloo blurb") # R52: the description feeds the pitch writer only, never a card
      options = html.css("select[data-filter-target='category'] option").map { |option| option["value"] }
      expect(options).to contain_exactly("", "Finance", "Coffee")
    end

    it "shows only a silhouette, the tier and a fit bucket on a locked row" do
      rows = html.css("[data-locked-match]")
      expect(rows.first.text.squish).to eq("•• Realistic High fit") # match 13: fit 87
      expect(rows.css("img, a, form, select, details")).to be_empty
      expect(html.at_css(".locked-matches ol")["aria-hidden"]).to eq("true")
    end
  end

  context "with 50 matches on an agent report" do
    before do
      (1..50).each { |i| create(:sponsor_match, report: report, position: i, name: "Brand #{format('%02d', i)}", category: %w[Finance Coffee][i % 2]) }
      render_section
    end

    it "shows the top 10 by default and the rest behind a collapsed Show all, which works without JS" do
      doc = html
      top = doc.at_css("ol.match-list")
      expect(top.css("[data-filter-target='item']").size).to eq(10)
      expect(top.text).to include("Brand 01", "Brand 10")
      expect(top.ancestors("details")).to be_empty

      details = doc.at_css("details.match-more")
      expect(details["open"]).to be_nil
      expect(details.at_css("summary").text.squish).to start_with("Show all 50 matches")
      more = details.at_css("ol.match-list")
      expect(more.css("[data-filter-target='item']").size).to eq(40)
      expect(more.text).to include("Brand 11", "Brand 50")
    end

    it "keeps the filters as one compact row inside the full list, hidden until JS shows it" do
      toolbar = html.at_css("details.match-more [data-filter-target='toolbar']")
      expect(toolbar["hidden"]).not_to be_nil
      expect(html.css("[data-filter-target='toolbar']").size).to eq(1)
    end
  end

  it "leaves out Show all and the filters with 10 matches or fewer" do
    create_list(:sponsor_match, 10, report: report)
    render_section
    expect(html.css("[data-filter-target='item']").size).to eq(10)
    expect(html.css("details.match-more, [data-filter-target='toolbar']")).to be_empty
  end

  it "shows every match of an agent report, whatever its owner's plan now is (R64)" do
    owner.update!(judge: false)
    expect(Entitlements.for(owner).visible_matches_limit).to eq(5)
    (1..8).each { |i| create(:sponsor_match, report: report, position: i, name: "Brand #{i}") }
    render_section

    expect(html.css("[data-filter-target='item']").size).to eq(8)
    expect(html.css("[data-locked-match]")).to be_empty
    expect(rendered).to include("Brand 8")
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

    it "shows logo initials, name, category, the fit score with its tier, and one reason line" do
      expect(card.at_css("h3").text.squish).to eq("Fieldnote Coffee")
      expect(card.at_css(".match-fit").text.squish).to eq("91 fit Easy yes")
      expect(card.text).to include("FC", "Coffee")
      expect(card.css("[data-match-reason]").map(&:text)).to eq([ "Your audience shares 6 taste signals with Fieldnote fans." ])
    end

    it "shows at most 3 evidence chips, with no scores: shared tastes, the newest proven show and how many other shows" do
      chips = card.css(".match-chips .chip").map { |chip| chip.text.squish }
      expect(chips).to eq([ "Shares 6 tastes", "Sponsors Harbor Lights", "+1 more show" ])
      expect(card.at_css(".chip em").text).to eq("Harbor Lights")
      expect(card.at_css(".match-chips").text).not_to include("0.82", "Affinity")
    end

    it "keeps the full evidence behind Why it fits, collapsed, with Qloo's data apart from the fit score (R86)" do
      why = card.at_css("details.match-why")
      expect(why["open"]).to be_nil
      expect(why.at_css("summary").text.squish).to eq("Why it fits")
      terms = why.css("dt").map(&:text)
      expect(terms).to eq([ "Qloo taste data", "Proven sponsor", "Midrolo fit score", "Website" ])
      expect(why.text.squish).to include("This audience likes Fieldnote Coffee much more than most people do.",
                                         "Shared tastes: A, B, C, D, E and F.", "Sponsored 4 episodes on similar shows.",
                                         "Sponsored Harbor Lights on “Ep 0”, Oct 12", "Sponsored Tide Tables on “Ep 1”, Oct 11",
                                         "91 of 100. Easy yes: a smaller brand, likely to welcome a show this size.")
      expect(why.text).not_to include("affinity", "0.82")
    end

    it "links the website safely, inside Why it fits" do
      link = card.at_css("details.match-why a[href='https://fieldnote.example.com/shop']")
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
      expect(form["action"]).to eq("/sponsor_matches/#{match.public_id}/pitch")
      expect(form["method"]).to eq("post")
      expect(form.at_css("button")["disabled"]).to be_nil
      expect(card.text).not_to include("coming soon")
      # A quiet button: the report's one primary action is its next step (R111).
      expect(form.at_css("button")["class"].split).to include("btn-secondary")
      expect(form.at_css("button")["class"].split).not_to include("btn-primary")
    end

    it "offers a live pipeline form: a labelled status select that saves on change, notes and a follow-up date" do
      match = report.sponsor_matches.first
      form = card.at_css("form##{ActionView::RecordIdentifier.dom_id(match, :status_form)}")
      expect(form["action"]).to eq("/sponsor_matches/#{match.public_id}")
      expect(form.at_css("input[name='_method']")["value"]).to eq("patch")
      expect(form["data-controller"]).to eq("status-form")

      select = form.at_css("select[name='sponsor_match[status]']")
      expect(select["disabled"]).to be_nil
      expect(select["data-action"]).to eq("status-form#submit")
      expect(select.css("option").map(&:text)).to eq(%w[Suggested Saved Pitched Replied Won Lost])
      expect(form.at_css("label[for='#{select['id']}']").text.squish).to eq("Pipeline status for Fieldnote Coffee")
      expect(form.at_css("noscript").inner_html).to include("Save")
      expect(form.at_css("[role='status']")).to be_present

      details = form.at_css("details.status-notes")
      expect(details["open"]).to be_nil
      expect(details.at_css("summary").text.squish).to eq("Notes & follow up")
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
      summary = html.at_css("details.status-notes summary")
      expect(summary.text.squish).to eq("Notes & follow up Note Follow up today")
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
      render(partial: "reports/sections/matches", locals: { report: running, read_only: false })

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
    expect(link.text.squish).to eq("Track this brand in your pipeline (Creator plan)")
  end

  it "opens the written pitch instead of writing another once the match has one" do
    match = create(:sponsor_match, report: report)
    Pitch.create!(sponsor_match: match, status: "done")
    render_section
    card = html.at_css("[data-filter-target='item']")
    link = card.at_css("a[href='/sponsor_matches/#{match.public_id}/pitch'][data-turbo-stream='true']")
    expect(link.text.squish).to eq("Open pitch")
    expect(link["class"].split).to include("btn-secondary") # R111
    expect(link["class"].split).not_to include("btn-primary")
    expect(card.at_xpath(".//button[contains(., 'Write my pitch')]")).to be_nil
  end

  it "leaves the tier line out of the unlock prompt when no locked tier is known" do
    report.update!(kind: "snapshot")
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
    report.update!(kind: "snapshot")
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
    badges = html.css("[data-filter-target='item'] .match-fit .badge").map(&:text)
    expect(badges).to eq([ "Easy yes", "Realistic", "Long shot" ])
  end

  it "reads a category with & or _and_ as and, on the row and in the category menu" do
    create(:sponsor_match, report: report, category: "Food & Beverage", position: 1, name: "HelloFresh")
    create(:sponsor_match, report: report, category: "health_and_wellness", position: 2)
    (3..12).each { |i| create(:sponsor_match, report: report, category: "Finance", position: i) }
    render_section

    expect(html.at_css("##{ActionView::RecordIdentifier.dom_id(report.sponsor_matches.first)} .match-category").text).to eq("Food and Beverage")
    options = html.css("select[data-filter-target='category'] option").to_h { |option| [ option.text, option["value"] ] }
    expect(options).to include("Food and Beverage" => "Food & Beverage", "Health and Wellness" => "health_and_wellness")
  end

  it "says what a realistic tier means, in Why it fits" do
    create(:sponsor_match, report: report, tier: "realistic", fit_score: 70)
    render_section
    expect(html.at_css("details.match-why").text.squish).to include("70 of 100. Realistic: a midsize brand, so lead with the fit.")
  end

  it "offers tier and proven filters, a category menu and a sort, all unset" do
    create(:sponsor_match, report: report, category: "Finance", position: 1)
    create(:sponsor_match, report: report, category: "Coffee", position: 2, evidence: proven("Harbor Lights"))
    (3..12).each { |i| create(:sponsor_match, report: report, category: "Finance", position: i) }
    render_section

    chips = html.css("button[aria-pressed]")
    expect(chips.map { |c| c.text.squish }).to eq([ "Easy yes", "Realistic", "Long shot", "Proven sponsors" ])
    expect(chips.map { |c| c["aria-pressed"] }.uniq).to eq([ "false" ])
    expect(html.css("select[data-filter-target='category'] option").map(&:text)).to eq([ "All categories", "Finance", "Coffee" ])
    expect(html.css("select[data-filter-target='sort'] option").map(&:text)).to eq([ "Best fit", "Easiest to land" ])
    expect(html.css("[data-filter-target='item']").map { |c| c["data-proven"] }.first(3)).to eq(%w[false true false])
  end

  it "leaves out the reason on a snapshot match" do
    report.update!(kind: "snapshot")
    create(:sponsor_match, report: report, reason: nil)
    render_section
    expect(html.css("[data-match-reason]")).to be_empty
    expect(html.at_css("details.match-why dt").text).to eq("Qloo taste data")
  end

  it "shows an older reason over 25 words as its first sentence on the row and in full in Why it fits" do
    long = "Fits this audience very well. #{'Its fans love slow travel and coffee. ' * 4}"
    create(:sponsor_match, report: report, reason: long)
    render_section
    expect(html.at_css("[data-match-reason]").text).to eq("Fits this audience very well.")
    expect(html.at_css("details.match-why dd").text.squish).to eq(long.squish)
  end

  it "says so when a finished report has no matches" do
    render_section
    expect(html.text).to include("No matches yet.")
    expect(html.css(".skeleton")).to be_empty
  end

  describe "read-only, as on a public sample (R78)" do
    def render_read_only = render(partial: "reports/sections/matches", locals: { report: report, read_only: true })

    it "shows each match without its pitch and pipeline actions" do
      create(:sponsor_match, report: report, name: "Fieldnote Coffee")
      render_read_only

      expect(html.text).to include("Fieldnote Coffee")
      expect(html.css(".match-actions, form, button[type='submit']")).to be_empty
      expect(html.text).not_to include("Write my pitch", "Pipeline")
    end

    it "says there are no matches without pointing to the show's settings" do
      render_read_only

      expect(html.text).to include("No matches yet.")
      expect(html.css("a")).to be_empty
    end
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
