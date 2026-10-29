require "rails_helper"

# Build spec L8's main flow in a real browser on the Fake providers: a podcaster runs a Snapshot, which finds the shows
# with a similar audience on Qloo and matches them to the catalog; the report lists them with links, and once the
# catalog knows a matched brand sponsors one of them, that brand's row carries the proof. Jobs run inline, so the
# Snapshot is done when its page loads.
RSpec.describe "Similar shows in a report" do
  around do |example|
    adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    Capybara.using_wait_time(10) { example.run }
  ensure
    ActiveJob::Base.queue_adapter = adapter
  end

  before do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = mock_google_auth(email: "maya@example.com", name: "Maya Brandt")
    allow(Llm).to receive(:mode).and_return(:fake)
    Taste::Provider.reset!
    Podcasts::Directory.reset!
    page.driver.browser.url_blacklist = [ %r{cdn\.jsdelivr\.net} ] # no MapLibre: the map isn't under test
    # The catalog already has every other podcast the Fake taste provider knows, linked to its Qloo entity.
    YAML.load_file(Taste::Providers::Fake::CATALOG_PATH).fetch("podcasts").each_key do |title|
      next if title == "The Founder's Ledger"

      create(:podcast, :active, title: title, qloo_entity_id: "fake:podcast:#{title.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')}")
    end
  end

  after { OmniAuth.config.mock_auth[:google_oauth2] = nil }

  it "lists the shows with a similar audience and puts the sponsor proof on the brand's match" do
    visit "/users/sign_in"
    click_button "Continue with Google"
    fill_in "Podcast title", with: "Founder"
    within("#search_results") { click_button "This is my show" }
    click_link "Skip for now"
    click_button "Get my free Snapshot"

    expect(page).to have_text("Report ready")
    within("#report_similar") do
      expect(page).to have_css("h2", text: "Shows with a similar audience")
      expect(page).to have_text("Taste data from Qloo")
      expect(page).to have_css("[data-similar-show]", count: 10)
      expect(page).to have_css("[data-similar-show] a[href^='/podcasts/']", count: 10) # all in the catalog
      expect(page).to have_no_text("The Founder's Ledger")
    end
    report = Report.sole
    expect(report.agent_steps.find_by(tool: "similar_podcasts").status).to eq("ok")

    # A feed shows the first visible match's brand sponsoring the closest similar show.
    match = report.sponsor_matches.first
    closest = Podcast.find(report.similar_podcasts.first["podcast_id"])
    brand = create(:brand, name: match.name)
    create(:sponsor_mention, brand: brand, episode: create(:episode, podcast: closest))
    visit current_path

    within("#report_similar [data-similar-brands]") { expect(page).to have_link(match.name) }
    within("##{ActionView::RecordIdentifier.dom_id(match)}") do
      expect(page).to have_css(".match-chips li", text: "Sponsors 1 show with your audience")
      find("summary", text: "Why it fits").click
      expect(page).to have_css("[data-similar-proof]", text: closest.title)
    end
  end
end
