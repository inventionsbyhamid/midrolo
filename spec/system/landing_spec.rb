require "rails_helper"

# The public pages in a real browser, at phone and desktop widths: nothing scrolls sideways, headings go down one level
# at a time, every image is labelled, text meets WCAG AA contrast and the focus ring shows. SCREENSHOTS=1 saves a
# full-page screenshot of each to tmp/screenshots/task19 (kept out of git).
RSpec.describe "Landing and public pages" do
  let(:widths) { { "375" => [ 375, 812 ], "1440" => [ 1440, 900 ] } }
  let(:pages) do
    { "home" => "/", "pricing" => "/pricing", "sample" => "/samples/#{first_sample_slug}", "samples" => "/samples",
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
    Samples::Generate.call(io: StringIO.new, entries: [ demo_sample_entry ])
  end

  def screenshot(name, width)
    return if ENV["SCREENSHOTS"].blank?

    dir = Rails.root.join("tmp/screenshots/task19")
    FileUtils.mkdir_p(dir)
    page.save_screenshot(dir.join("#{name}-#{width}.png").to_s, full: true)
  end

  # What the landing page shows once there's something real to show: the How Midrolo works video, the demo show's
  # listing and shows from the directory, so the layout checks cover them too.
  def fill_the_marketplace
    AppSettings.set(:explainer_video_id, "-UXzujILAoI")
    create(:user, admin: true)
    Claims::DemoSetup.call
    [ "Index Fund Mornings", "The Founder's Ledger", "Cold Case Cafe" ].each_with_index do |title, i|
      create(:podcast, :indexable, :with_artwork, title: title, author: "Host #{i + 1}", open_to_sponsors: i.zero?)
    end
  end

  # One example walks every page at both widths: a browser session per page would cost seconds each.
  it "lays out every public page at 375px and 1440px with ordered headings, labelled images and AA contrast",
     :aggregate_failures do
    generate_sample
    fill_the_marketplace

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
      break if evaluate_script("document.activeElement.textContent.trim()") == "Find podcasts your customers love"

      page.driver.browser.keyboard.type(:tab)
    end

    expect(evaluate_script("document.activeElement.closest('#hero') !== null")).to be(true)
    expect(focus_outline_style).to eq("solid")
  end

  it "takes a brand to the fit search and a podcaster to their show from the landing page" do
    fill_the_marketplace
    page.driver.resize(1440, 900)
    visit "/"

    expect(page).to have_css("#for-brands .dir-card", count: 3)
    expect(page).to have_css("#for-podcasters .listing-rates", text: "Demo show")
    within("#hero") { click_link "Find podcasts your customers love" }
    expect(page).to have_current_path("/users/sign_in") # the fit search needs an account; sign in comes back to it

    visit "/"
    within("#hero") { click_link "Get your show sponsored" }
    within("#for-podcasters") do
      fill_in "Your show's name", with: "Cold Case"
      click_button "Find my show"
    end
    expect(page).to have_current_path(%r{\A/podcasts\?q=Cold})
    expect(page).to have_css(".dir-card", text: "Cold Case Cafe")
  end

  # The connections lite-youtube-embed warms for YouTube's player, which youtube_controller adds on intent.
  def youtube_hosts = [ "https://www.youtube-nocookie.com", "https://www.google.com", "https://i.ytimg.com",
                         "https://googleads.g.doubleclick.net", "https://static.doubleclick.net" ]

  def preconnects = evaluate_script("[...document.querySelectorAll('link[rel=preconnect]')].map((link) => link.getAttribute('href'))")
  def video_dialog_box = evaluate_script("(({ width, height }) => [ width, height ])(document.querySelector('dialog.video-dialog').getBoundingClientRect())")
  def focused_label = evaluate_script("document.activeElement.getAttribute('aria-label')")

  # Nothing comes from YouTube until play is pressed. Pointing at the play button only warms connections to YouTube's
  # hosts, once; pressing it opens a large dialog with the privacy-enhanced player, playing. Escape, the close button
  # and the backdrop each close it, which removes the player and gives focus back. The player's own page isn't needed
  # here, so the browser doesn't fetch it.
  it "plays How Midrolo works in a dialog from youtube-nocookie.com only once its play button is pressed" do
    AppSettings.set(:explainer_video_id, "-UXzujILAoI")
    page.driver.browser.url_blacklist = [ %r{cdn\.jsdelivr\.net}, %r{\Ahttps://www\.youtube-nocookie\.com/} ]
    page.driver.resize(1440, 900)
    visit "/"

    play = find("#how-it-works button.video-play[aria-label='Watch how it works, 2 min video'][aria-haspopup='dialog']") # the link, made a button
    expect(page).to have_no_css("#how-it-works a.video-play")
    expect(page).to have_no_css("iframe")
    expect(preconnects & youtube_hosts).to be_empty # not on page view

    # The 2x poster, as WebP, from here rather than YouTube: a 1x window picks the 1280px one for the ~700px box.
    scroll_to(play, align: :center)
    page.document.synchronize do
      evaluate_script("document.querySelector('#how-it-works img.video-poster').complete") || raise(Capybara::ExpectationNotMet, "no poster yet")
    end
    expect(evaluate_script("document.querySelector('#how-it-works img.video-poster').currentSrc"))
      .to match(%r{/assets/explainer/poster-1280-\h+\.webp\z})

    play.hover
    expect(preconnects & youtube_hosts).to eq(youtube_hosts)
    execute_script("document.querySelector('#how-it-works .video-play').focus()") # intent again: still once each
    expect(preconnects.tally.slice(*youtube_hosts)).to eq(youtube_hosts.index_with(1))
    expect(page.driver.network_traffic.map(&:url).grep(%r{youtube(?:-nocookie)?\.com|youtu\.be|ytimg\.com|google\.com|doubleclick})).to be_empty

    play.click
    frame = find("dialog.video-dialog[open][aria-label='How Midrolo works'] iframe.video-frame")
    expect(frame[:src]).to eq("https://www.youtube-nocookie.com/embed/-UXzujILAoI?autoplay=1&rel=0&playsinline=1")
    expect(frame[:title]).to eq("How Midrolo works")
    expect(frame[:allow]).to eq("autoplay; encrypted-media; picture-in-picture; fullscreen")
    expect(evaluate_script("document.querySelector('dialog.video-dialog iframe').allowFullscreen")).to be(true)
    expect(focused_label).to eq("Close video") # focus moves into the dialog
    expect(video_dialog_box).to eq([ 1280, 720 ]) # 90% of the window, at most 1280px, 16:9

    page.driver.browser.keyboard.type(:escape)
    expect(page).to have_no_css("dialog.video-dialog[open]")
    expect(page).to have_no_css("iframe") # playback stops with the player
    expect(focused_label).to eq("Watch how it works, 2 min video")

    play.click # a fresh player each time
    expect(page).to have_css("dialog.video-dialog[open] iframe", count: 1)
    find("dialog.video-dialog button[aria-label='Close video']").click
    expect(page).to have_no_css("dialog.video-dialog[open]")
    expect(page).to have_no_css("iframe")
    expect(focused_label).to eq("Watch how it works, 2 min video")

    play.click
    expect(page).to have_css("dialog.video-dialog[open] iframe")
    page.driver.browser.mouse.click(x: 40, y: 450) # the backdrop, left of the player
    expect(page).to have_no_css("dialog.video-dialog[open]")
    expect(page).to have_no_css("iframe")

    # The full width on a phone.
    page.driver.resize(375, 812)
    play.click
    expect(page).to have_css("dialog.video-dialog[open] iframe")
    expect(video_dialog_box).to eq([ 375, 210.9375 ])
  end

  it "has checks that catch what they look for" do
    visit "/about"
    # The colors go on through the CSSOM: the Content Security Policy blocks style attributes.
    execute_script(<<~JS)
      document.querySelector("main").insertAdjacentHTML("beforeend",
        '<p id="faint">Faint text</p><img src="/icon-192.png"><h4>Skipped</h4>')
      Object.assign(document.getElementById("faint").style, { color: "#b9aec0", background: "#fff" })
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
