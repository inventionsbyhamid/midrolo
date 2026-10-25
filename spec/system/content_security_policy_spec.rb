require "rails_helper"

# The Content Security Policy (R10, config/initializers/content_security_policy.rb) in a real browser: the landing
# page, a finished report whose map loads MapLibre (and its worker) from jsDelivr and its style and tiles from
# OpenFreeMap (the real style, not the blank one other specs use), and a public kit with its map. Chrome reports every
# load, inline script or style the policy blocks in the console; none may appear. The map needs the network.
RSpec.describe "Content Security Policy", :network do
  include Warden::Test::Helpers

  let(:owner) { create(:user, judge: true) }

  around { |example| Capybara.using_wait_time(10) { example.run } }

  before do
    allow(Llm).to receive(:mode).and_return(:fake)
    Taste::Provider.reset!
    Podcasts::Directory.reset!
    @blocked = []
    # Chrome logs each blocked load (a "security" message, or "worker" for a worker script) with the policy's name.
    page.driver.browser.page.on("Log.entryAdded") do |params|
      text = params.dig("entry", "text").to_s
      @blocked << text if text.include?("Content Security Policy")
    end
  end

  def run_report(user)
    show = user.shows.create!(ShowLookup.call(directory_id: "fake-2").attributes.merge(downloads_per_episode: 1500))
    report = show.reports.create!(kind: "agent", status: "queued", spend_bucket: "paid")
    GenerateReportJob.perform_now(report.id)
    report.reload.tap { |done| expect(done).to be_done }
  end

  # The map has drawn: MapLibre loaded, its style, tiles and worker ran, and the heatmap layer is on.
  def expect_map_drawn(id)
    scroll_to(find("##{id}"), align: :center) # MapLibre loads once the map nears the viewport
    expect(page).to have_css("##{id} canvas.maplibregl-canvas", wait: 30)
    expect(page).to have_css("##{id} [data-map-target='status']", visible: :hidden, wait: 30)
    expect(page).to have_css("##{id}:not([hidden])")
    sleep 1 # tiles and glyphs arrive after the first frame
  end

  def add_script(src) = execute_script(%(document.head.append(Object.assign(document.createElement("script"), { src: #{src.to_json} }))))

  def expect_blocked(src)
    page.document.synchronize { @blocked.any? { |text| text.include?(src) } || raise(Capybara::ExpectationNotMet, "#{src} not blocked") }
  end

  # The policy refuses these before any request goes out.
  it "notices a blocked script, so a quiet console means something, and blocks jsDelivr outside MapLibre's folder" do
    visit "/"
    add_script("https://example.com/x.js")
    expect_blocked("https://example.com/x.js")
    add_script("https://cdn.jsdelivr.net/npm/left-pad@1.3.0/index.js")
    expect_blocked("https://cdn.jsdelivr.net/npm/left-pad@1.3.0/index.js")
  end

  # The page's menu button works: Stimulus has connected its dialog controller.
  def wait_for_menu
    page.document.synchronize do
      evaluate_script(<<~JS) || raise(Capybara::ExpectationNotMet, "the menu's controller isn't connected")
        !!(window.Stimulus && Stimulus.getControllerForElementAndIdentifier(document.querySelector("[data-controller='dialog']"), "dialog"))
      JS
    end
  end

  # A visitor's first page has no session yet, so it gets a nonce of its own; the next one has the session's (in
  # production the first page's CSRF token leaves a session behind, as here). Turbo keeps the first page's policy for
  # the visit, so this is the moment a script added with the new page's nonce would be blocked.
  it "keeps the app's scripts running through a Turbo visit from a visitor's first page, where the nonce changes" do
    ActionController::Base.allow_forgery_protection = true
    page.driver.resize(375, 812)
    visit "/"
    expect(page).to have_css("h1", text: "Find sponsors who already love your listeners")
    wait_for_menu
    first_nonce = find("meta[name='csp-nonce']", visible: :all)[:content]
    execute_script("window.firstDocument = true")

    click_button "Menu"
    within("dialog[open]") { click_link "Pricing" }
    expect(page).to have_css("h1", text: "Pricing")
    expect(evaluate_script("window.firstDocument")).to be(true) # Turbo swapped the page in, under the first policy
    expect(find("meta[name='csp-nonce']", visible: :all)[:content]).not_to eq(first_nonce)

    wait_for_menu # the dialog controller Stimulus connected on the new page
    click_button "Menu"
    expect(page).to have_css("dialog[open]")
    expect(@blocked).to be_empty, @blocked.join("\n")
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  it "blocks nothing on the landing page, a report with its map, or a public kit" do
    visit "/"
    expect(page).to have_css("h1")
    expect(evaluate_script("typeof window.Stimulus")).to eq("object") # the app's JavaScript ran
    expect(@blocked).to be_empty, @blocked.join("\n")

    report = run_report(owner)
    login_as(owner, scope: :user)
    visit show_report_path(report.show, report)
    expect_map_drawn("report_map")
    expect(@blocked).to be_empty, @blocked.join("\n")

    create(:media_kit, :published, show: report.show)
    visit public_kit_path(report.show.reload.slug)
    expect(page).to have_css(".age-bar-fill[data-segments]", minimum: 1, visible: :all)
    expect(page.find(".age-bar[data-lean='over'] .age-bar-fill", match: :first).evaluate_script("this.offsetHeight")).to be > 0
    expect_map_drawn("kit_heatmap")
    expect(@blocked).to be_empty, @blocked.join("\n")
  end
end
