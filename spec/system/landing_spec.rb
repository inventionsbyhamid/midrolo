require "rails_helper"

# The public pages in a real browser, at phone and desktop widths: nothing scrolls sideways, headings go down one level
# at a time, every image is labelled, text meets WCAG AA contrast and the focus ring shows. SCREENSHOTS=1 saves a
# full-page screenshot of each to tmp/screenshots/task19 (kept out of git).
RSpec.describe "Landing and public pages" do
  let(:widths) { { "375" => [ 375, 812 ], "1440" => [ 1440, 900 ] } }
  let(:pages) do
    { "home" => "/", "pricing" => "/pricing", "sample" => "/samples/sample-one", "samples" => "/samples",
      "privacy" => "/privacy", "terms" => "/terms", "about" => "/about" }
  end

  around { |example| Capybara.using_wait_time(10) { example.run } }

  before do
    page.driver.browser.url_blacklist = [ %r{cdn\.jsdelivr\.net} ] # no MapLibre: the Top metros list stands alone
    # Reduced motion: the hero's load animation ends at once, so checks and screenshots see the finished page.
    page.driver.browser.page.command("Emulation.setEmulatedMedia",
                                     features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
  end

  # The first sample, run on the Fake providers, for the pages that show one.
  def generate_sample
    Taste::Provider.reset!
    Podcasts::Directory.reset!
    Samples::Generate.call(io: StringIO.new, entries: Samples.entries.first(1))
  end

  def screenshot(name, width)
    return if ENV["SCREENSHOTS"].blank?

    dir = Rails.root.join("tmp/screenshots/task19")
    FileUtils.mkdir_p(dir)
    page.save_screenshot(dir.join("#{name}-#{width}.png").to_s, full: true)
  end

  # One example walks every page at both widths: a browser session per page would cost seconds each.
  it "lays out every public page at 375px and 1440px with ordered headings, labelled images and AA contrast",
     :aggregate_failures do
    generate_sample

    pages.each do |name, path|
      widths.each do |width, (w, h)|
        page.driver.resize(w, h)
        visit path
        at = "#{path} at #{width}px"

        expect(page).to have_css("h1")
        expect(horizontal_overflow).to eq(0), "#{at} scrolls sideways"
        expect(heading_levels.count(1)).to eq(1), "#{at} has #{heading_levels.count(1)} h1s"
        expect(skipped_heading_levels).to be_empty, "#{at} skips #{skipped_heading_levels.join(', ')}"
        expect(unlabelled_images).to be_empty, "#{at}: #{unlabelled_images.join('; ')}"
        expect(contrast_failures).to be_empty, "#{at}: #{contrast_failures.join('; ')}"
        screenshot(name, width)
      end
    end
  end

  it "shows the focus ring on the hero's call to action when tabbed to" do
    visit "/"
    20.times do
      break if evaluate_script("document.activeElement.textContent.trim()") == "Get my free Snapshot"

      page.driver.browser.keyboard.type(:tab)
    end

    expect(evaluate_script("document.activeElement.closest('#hero') !== null")).to be(true)
    expect(focus_outline_style).to eq("solid")
  end

  it "has checks that catch what they look for" do
    visit "/about"
    execute_script(<<~JS)
      document.querySelector("main").insertAdjacentHTML("beforeend",
        '<p style="color: #b9aec0; background: #fff">Faint text</p><img src="/icon-192.png"><h4>Skipped</h4>')
    JS

    expect(contrast_failures).to include(a_string_including("Faint text"))
    expect(unlabelled_images).to include(a_string_including("icon-192.png"))
    expect(skipped_heading_levels).to include("h2 → h4")
  end

  it "switches the paid plans between monthly and yearly prices" do
    visit "/pricing"

    creator = find(".plan-card[data-plan='creator']")
    expect(creator).to have_css("[data-interval='monthly']", text: "$19")
    expect(creator).to have_no_css("[data-interval='yearly']")

    choose "Yearly", allow_label_click: true
    expect(creator).to have_css("[data-interval='yearly']", text: "$190")
    expect(creator).to have_no_css("[data-interval='monthly']")

    page.driver.browser.keyboard.type(:left) # arrow keys move between the radios
    expect(creator).to have_css("[data-interval='monthly']", text: "$19")
  end
end
