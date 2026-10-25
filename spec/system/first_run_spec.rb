require "rails_helper"

# A brand-new user's first visit, in a real browser on the Fake providers, with billing on the founding member
# waitlist (the default): the landing page, sign in, adding a show, a free Snapshot, the upgrade prompt for a full
# report, and pricing. Every page has one primary next action and none is a dead end. Jobs run inline, so the
# Snapshot is done when its page loads. SCREENSHOTS=1 saves each page at 375px and 1440px to tmp/screenshots/t20
# (kept out of git).
RSpec.describe "First run" do
  around do |example|
    adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    with_billing_env { Capybara.using_wait_time(10) { example.run } }
  ensure
    ActiveJob::Base.queue_adapter = adapter
  end

  before do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = mock_google_auth(email: "new@example.com", name: "Nia Newcomer")
    AppSettings.set(:promo_pro_until, "2026-01-01") # after the promo: a new account is on the free plan
    allow(Llm).to receive(:mode).and_return(:fake)
    Taste::Provider.reset!
    Podcasts::Directory.reset!
    page.driver.browser.url_blacklist = [ %r{cdn\.jsdelivr\.net} ] # no MapLibre: the Top places line stands alone
  end

  after { OmniAuth.config.mock_auth[:google_oauth2] = nil }

  # The page's (or the current within scope's) primary action: a visible primary button or link with this name.
  def expect_primary_action(name)
    expect(page).to have_css(".btn-primary", visible: true) # waits for the page
    primary = all(".btn-primary", visible: true).map { |node| node.tag_name == "input" ? node.value : node.text.squish }
    expect(primary).to include(name)
  end

  # Every page names itself and the app in the tab ("Sign in | Midrolo"; the landing page leads with the name).
  def screenshot(name)
    expect(page).to have_title(/Midrolo/)
    return if ENV["SCREENSHOTS"].blank?

    dir = Rails.root.join("tmp/screenshots/t20")
    FileUtils.mkdir_p(dir)
    { 375 => 812, 1440 => 900 }.each do |width, height|
      page.driver.resize(width, height)
      expect(horizontal_overflow).to eq(0), "#{name} scrolls sideways at #{width}px"
      page.save_screenshot(dir.join("first-run-#{name}-#{width}.png").to_s, full: true)
    end
    page.driver.resize(1400, 1000)
  end

  it "takes a new user from the landing page to a Snapshot, the upgrade prompt and pricing with no dead ends" do
    visit "/"
    expect(page).to have_css("h1")
    within("#hero") { expect_primary_action("Get my free Snapshot") }
    screenshot("landing")
    within("#hero") { click_link "Get my free Snapshot" }

    expect(page).to have_current_path("/users/sign_in")
    expect(page).to have_title("Sign in | Midrolo")
    expect_primary_action("Continue with Google")
    screenshot("sign-in")
    click_button "Continue with Google"

    # No shows yet, so the app goes straight to adding one, and the welcome email is on its way.
    expect(page).to have_current_path("/shows/new")
    expect(ActionMailer::Base.deliveries.map { |mail| [ mail.to, mail.subject ] }).to eq([ [ [ "new@example.com" ], "Welcome to Midrolo" ] ])
    expect(page).to have_css("h1", text: "Find your show")
    expect(page).to have_field("Podcast title", focused: true) # the next action: type the show's name
    screenshot("add-show")
    fill_in "Podcast title", with: "Founder"
    within("#search_results") do
      expect_primary_action("This is my show")
      click_button "This is my show"
    end

    expect(page).to have_css("h1", text: "The Founder's Ledger")
    expect_primary_action("Save and continue")
    screenshot("details")
    fill_in "Downloads per episode", with: "1500"
    click_button "Save and continue"

    expect(page).to have_text("Details saved.")
    expect_primary_action("Get my free Snapshot")
    screenshot("show")
    # A keyboard reaches the next action, and the focus ring shows on it.
    30.times do
      break if evaluate_script("document.activeElement.textContent.trim()") == "Get my free Snapshot"

      page.driver.browser.keyboard.type(:tab)
    end
    expect(evaluate_script("document.activeElement.textContent.trim()")).to eq("Get my free Snapshot")
    expect(focus_outline_style).to eq("solid")
    page.driver.browser.keyboard.type(:enter)

    expect(page).to have_text("Report ready")
    within("#report_summary") do
      expect(page).to have_text("This is your free Snapshot")
      expect_primary_action("Run full report")
    end
    expect(page).to have_css("[data-locked-match]", minimum: 1) # the rest of the matches wait behind an upgrade
    # One primary action on the page, the next step; a row's Write my pitch is a quiet button (R111).
    expect(all("main .btn-primary", visible: true).map { |node| node.text.squish }).to eq([ "Run full report" ])
    screenshot("snapshot")

    # The free plan writes no pitches: a row's Write my pitch opens the upgrade prompt instead.
    first(".match-row button", text: "Write my pitch").click
    within("dialog[open]") do
      prompt = find(".upgrade-prompt", text: "Pitch packs are on Creator and up")
      expect(prompt).to have_link("See plans", href: "/pricing")
      find("button[aria-label='Close']").click
    end
    expect(page).to have_no_css("dialog[open]")

    within("#report_summary") { click_button "Run full report" }

    # A free plan has no full reports: the show page says why, with the way on.
    prompt = find(".upgrade-prompt", text: "Full agent reports are on Creator and up")
    expect(prompt).to have_link("See plans")
    screenshot("upgrade-prompt")
    within(prompt) { click_link "See plans" }

    expect(page).to have_current_path("/pricing")
    within(".plan-card[data-plan='creator']") do
      expect(page).to have_button("Join the founding member waitlist")
      click_button "Join the founding member waitlist"
    end
    expect(page).to have_text("You're on the founding member list.")
    screenshot("pricing")
    expect(WaitlistEntry.sole).to have_attributes(email: "new@example.com", price_key: "creator_monthly")
  end
end
