require "rails_helper"

# The public catalog in a real browser (lane L3): a search for a show the catalog lacks adds it from the demo directory
# (Catalog::LazyAdd), the card says it's being added and swaps for the real one once Catalog::IngestPodcastJob has read
# its feed, and the page opens. Then each catalog page at phone and desktop widths:
# nothing scrolls sideways, headings go down one level at a time, images are labelled and text meets AA contrast.
# Full-page screenshots go to tmp/catalog_screenshots when SCREENSHOTS is set or tmp/catalog_screenshots.enabled exists
# (bin/remote-rspec doesn't pass the environment on).
RSpec.describe "The public catalog" do
  include ActiveJob::TestHelper

  around { |example| Capybara.using_wait_time(10) { example.run } }

  before do
    stub_const("PodcastsController::POLL_DELAY", 300)
    page.driver.browser.page.command("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
  end

  def screenshot(name)
    dir = Rails.root.join("tmp/catalog_screenshots")
    return unless ENV["SCREENSHOTS"].present? || Rails.root.join("tmp/catalog_screenshots.enabled").exist?

    FileUtils.mkdir_p(dir)
    page.save_screenshot(dir.join("#{name}.png").to_s, full: true)
  end

  # What Catalog::IngestPodcastJob leaves behind once the feed is read.
  def finish_ingest(podcast)
    podcast.update!(status: "active", indexable: true, author: "Jack Rhysider", episode_count: 3, cadence_days: 14,
                    description: "True stories from the dark side of the internet.", categories: [ "Technology" ],
                    first_published_at: 2.years.ago, last_published_at: 3.days.ago, feed_checked_at: 1.minute.ago)
    brand = create(:brand, name: "ThreatLocker")
    3.times do |i|
      episode = create(:episode, podcast: podcast, title: "Episode #{i + 1}: A story", published_at: (i * 14 + 3).days.ago, duration_seconds: 3_000)
      create(:sponsor_mention, episode: episode, brand: brand, promo_code: "DARKNET") if i < 2
    end
    create(:podcast_person, podcast: podcast, name: "Jack Rhysider", role: "host")
  end

  it "adds a searched show the catalog lacks, shows it as being added, then opens its page once it's read" do
    Podcasts::Directory.reset!
    allow(MediaKit).to receive(:bot?).and_return(false) # headless Chrome says so in its user agent
    create(:podcast, :indexable, title: "Ledger Lines", categories: [ "Business" ])

    visit "/podcasts"
    fill_in "Search podcasts", with: "ledger"
    click_button "Search"

    expect(page).to have_css("h2", text: "Results for \"ledger\"")
    expect(page).to have_link("Ledger Lines")
    within("#adding_podcasts") { expect(page).to have_text("The Founder's Ledger").and have_text("Adding this show") }
    added = Podcast.find_by!(title: "The Founder's Ledger")
    expect(added).to have_attributes(status: "pending", source: "search")
    screenshot("search-adding")

    perform_enqueued_jobs(only: Catalog::IngestPodcastJob)
    expect(added.reload).to be_active
    within("#adding_podcasts") do
      expect(page).to have_no_text("Adding this show")
      click_link "The Founder's Ledger"
    end

    expect(page).to have_css("h1", text: "The Founder's Ledger")
    expect(page).to have_css("#episodes .ep-row", minimum: 3)
    expect(page).to have_text("Feed checked just now.")
  end

  it "fills a pending show's page in once its feed is read" do
    podcast = create(:podcast, status: "pending", title: "Fresh From Search")
    visit "/podcasts/#{podcast.slug}"
    expect(page).to have_text("Reading this show's feed.")

    finish_ingest(podcast)
    expect(page).to have_css("#about", text: "True stories from the dark side of the internet.")
    expect(page).to have_no_text("Reading this show's feed.")
  end

  it "lays out the catalog's pages at 375px and 1440px with ordered headings, labelled images and AA contrast", :aggregate_failures do
    podcast = create(:podcast, status: "pending", title: "Darknet Diaries", categories: [ "Technology", "News" ], language: "en",
                               feed_url: "https://feeds.example.com/darknet.xml", website: "https://darknetdiaries.com",
                               apple_id: 1_296_350_485, hosting_provider: "megaphone", measurement: [ "podtrac" ])
    finish_ingest(podcast)
    owner = create(:show, podcast: podcast)
    create(:media_kit, :published, show: owner, open_months: [ 1.month.from_now.strftime("%Y-%m") ], looking_for: "Security tools for small teams.")
    podcast.reload.update!(open_to_sponsors: true, min_price_cents: 30_000)
    2.times { |i| create(:podcast, :indexable, title: "Similar Show #{i + 1}", categories: [ "Technology" ], author: "Someone") }
    episode = podcast.episodes.newest_first.first
    brand = Brand.find_by!(name: "ThreatLocker")

    pages = { "directory" => "/podcasts", "podcast" => "/podcasts/#{podcast.slug}",
              "episode" => "/podcasts/#{podcast.slug}/episodes/#{episode.slug}", "category" => "/podcasts/category/technology",
              "brand" => "/brands/#{brand.slug}", "remove" => "/podcasts/#{podcast.slug}/remove", "data-sources" => "/data-sources" }
    { "375" => [ 375, 812 ], "1440" => [ 1440, 900 ] }.each do |width, (w, h)|
      page.driver.resize(w, h)
      pages.each do |name, path|
        visit path
        at = "#{path} at #{width}px"
        expect(page).to have_css("h1")
        expect(horizontal_overflow).to eq(0), "#{at} scrolls sideways"
        expect(heading_levels.count(1)).to eq(1), "#{at} has #{heading_levels.count(1)} h1s"
        expect(skipped_heading_levels).to be_empty, "#{at} skips #{skipped_heading_levels.join(', ')}"
        expect(unlabelled_images).to be_empty, "#{at}: #{unlabelled_images.join('; ')}"
        expect(contrast_failures).to be_empty, "#{at}: #{contrast_failures.join('; ')}"
        screenshot("#{name}-#{width}")
      end
    end
  end
end
