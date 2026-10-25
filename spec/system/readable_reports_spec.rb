require "rails_helper"

# R99: a finished report reads top to bottom in under a minute. In a real browser on the Fake providers, the owner's
# agent report, a free Snapshot, a public sample and a public kit each lay out at 375px and 1440px with no sideways
# scroll, headings in order, labelled images and AA contrast; the collapsed sample stays under 4,000px at 1440px.
# SCREENSHOTS=1 saves full-page shots to tmp/screenshots/r1 (kept out of git).
RSpec.describe "Readable reports" do
  include ActiveJob::TestHelper
  include Warden::Test::Helpers

  let(:widths) { { "375" => [ 375, 812 ], "1440" => [ 1440, 900 ] } }
  let(:owner) { create(:user, judge: true) }

  around { |example| Capybara.using_wait_time(10) { example.run } }

  before do
    allow(Llm).to receive(:mode).and_return(:fake)
    Taste::Provider.reset!
    Podcasts::Directory.reset!
    page.driver.browser.url_blacklist = [ %r{cdn\.jsdelivr\.net} ] # no MapLibre: the frame keeps its CSS height
  end

  def generate_sample = Samples::Generate.call(io: StringIO.new, entries: Samples.entries.first(1))

  # A finished report of kind on the Fake providers, for a show of user's.
  def run_report(user, kind, directory_id: "fake-2")
    show = user.shows.find_by(directory_id: directory_id) ||
           user.shows.create!(ShowLookup.call(directory_id: directory_id).attributes.merge(downloads_per_episode: 1500))
    report = show.reports.create!(kind: kind, status: "queued", spend_bucket: (kind == "agent" ? "paid" : nil))
    (kind == "agent" ? GenerateReportJob : BuildSnapshotJob).perform_now(report.id)
    report.reload.tap { |done| expect(done).to be_done }
  end

  def page_height = evaluate_script("document.documentElement.scrollHeight")

  def screenshot(name, width)
    return if ENV["SCREENSHOTS"].blank?

    dir = Rails.root.join("tmp/screenshots/r1")
    FileUtils.mkdir_p(dir)
    page.save_screenshot(dir.join("#{name}-#{width}.png").to_s, full: true)
  end

  # The disclosures open (See all tastes, How we built this and the first Why it fits), at 1440px. The full list
  # stays shut: fifty rows would outgrow a screenshot.
  def expanded_screenshot(name)
    return if ENV["SCREENSHOTS"].blank?

    page.driver.resize(1440, 900)
    execute_script(<<~JS)
      document.querySelectorAll("details.taste-more, details.report-how").forEach((d) => { d.open = true })
      document.querySelector("details.match-why").open = true
    JS
    screenshot(name, 1440)
  end

  def check_layout(name, path)
    widths.each do |width, (w, h)|
      page.driver.resize(w, h)
      visit path
      at = "#{name} at #{width}px"

      expect(page).to have_css("h1")
      expect(horizontal_overflow).to eq(0), "#{at} scrolls sideways"
      expect(skipped_heading_levels).to be_empty, "#{at} skips #{skipped_heading_levels.join(', ')}"
      expect(unlabelled_images).to be_empty, "#{at}: #{unlabelled_images.join('; ')}"
      expect(contrast_failures).to be_empty, "#{at}: #{contrast_failures.join('; ')}"
      expect(page).to have_no_css("details[open]:not(.rail)") # every disclosure starts collapsed
      screenshot(name, width)
    end
  end

  it "lays out the sample, the owner's report, a Snapshot and the public kit at 375px and 1440px", :aggregate_failures do
    generate_sample
    report = run_report(owner, "agent")
    snapshot = run_report(create(:user), "snapshot", directory_id: "fake-1")
    create(:media_kit, :published, show: report.show)

    check_layout("sample", "/samples/sample-one")
    login_as(owner, scope: :user)
    check_layout("agent", show_report_path(report.show, report))
    expanded_screenshot("agent-open")
    check_layout("kit", public_kit_path(report.show.reload.slug))
    login_as(snapshot.show.user, scope: :user)
    check_layout("snapshot", show_report_path(snapshot.show, snapshot))
    expect(page).to have_css("[data-locked-match]", minimum: 1)
  end

  it "keeps the collapsed sample page under 4,000px tall at 1440px, with At a glance and the first match on the first screen" do
    generate_sample
    page.driver.resize(1440, 900)
    visit "/samples/sample-one"
    expect(page).to have_css("h1")

    height = page_height
    Rails.logger.info("R1 sample page height at 1440px: #{height}")
    puts "R1 sample page height at 1440px: #{height}" if ENV["SCREENSHOTS"].present?
    expect(height).to be < 4000
    first_row = evaluate_script("document.querySelector('#report_matches .match-row').getBoundingClientRect().top")
    expect(first_row).to be < 900
  end

  it "opens the full match list with its filters, filters it, and puts everything back when it closes" do
    report = run_report(owner, "agent")
    login_as(owner, scope: :user)
    visit show_report_path(report.show, report)
    total = all("[data-filter-target='item']", visible: :all).size
    expect(total).to be > 10

    expect(page).to have_css("[data-filter-target='item']", count: 10) # visible ones: the top 10
    expect(page).to have_no_button("Easy yes")
    find("details.match-more > summary").click
    expect(page).to have_css("[data-filter-target='item']", count: total)

    click_button "Easy yes"
    easy = all("[data-filter-target='item'][data-tier='easy_yes']", visible: :all).size
    expect(page).to have_text("Showing #{easy} of #{total}")
    expect(page).to have_no_css("[data-filter-target='item']:not([data-tier='easy_yes'])")

    find("details.match-more > summary").click
    expect(page).to have_no_button("Easy yes")
    expect(page).to have_css("[data-filter-target='item']", count: 10)
    expect(page).to have_no_css("button[aria-pressed='true']", visible: :all)
  end

  it "opens the full list when a link points at a row inside it" do
    report = run_report(owner, "agent")
    deep = report.sponsor_matches.order(:position).last
    login_as(owner, scope: :user)
    visit show_report_path(report.show, report, anchor: ActionView::RecordIdentifier.dom_id(deep))

    expect(page).to have_css("details.match-more[open]")
    expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(deep)}", visible: true)
  end
end
