require "rails_helper"

# Lane L2's main flow in a real browser: new episodes come in, the sponsor scan runs (fake LLM mode, so patterns only),
# and what it found shows on the admin dashboard, on the podcast page with its evidence, and on the brand page.
RSpec.describe "Sponsor history" do
  include Warden::Test::Helpers

  around do |example|
    saved = ENV.values_at("ADMIN_USERNAME", "ADMIN_PASSWORD")
    ENV.delete("ADMIN_USERNAME")
    ENV.delete("ADMIN_PASSWORD")
    example.run
  ensure
    ENV["ADMIN_USERNAME"], ENV["ADMIN_PASSWORD"] = saved
  end

  before { allow(Llm).to receive(:mode).and_return(:fake) }

  after { Warden.test_reset! }

  let!(:scanned) do
    podcast, episode = podcast_from_fixture("host_reads")
    Sponsors::ScanJob.perform_now(podcast.id, [ episode.id ])
    [ podcast, episode ]
  end

  it "shows the reads the scan found on the admin dashboard" do
    login_as(create(:user, admin: true), scope: :user)
    visit "/admin"

    within(:xpath, "//section[.//h2[normalize-space()='Sponsor detection']]") do
      expect(page).to have_text(/3\s+Sponsor reads/)
      expect(page).to have_text("Helix Sleep")
      expect(page).to have_text("The Tinkerer Hour")
      expect(page).to have_text("use code TIM")
    end
  end

  it "shows the sponsor history on the podcast page" do
    podcast, episode = scanned
    visit Rails.application.routes.url_helpers.podcast_path(podcast)

    within("[data-testid='sponsor-history']") do
      expect(page).to have_link("Helix Sleep")
      expect(page).to have_css(".chip", text: "Code TIM")
      expect(page).to have_text("This episode is brought to you by AG1.")
      click_link episode.title, match: :first
    end
    expect(page).to have_current_path(%r{/episodes/#{episode.slug}\z})
  end

  it "shows the brand page's shows from the sponsor history" do
    podcast, = scanned
    brand = Brand.find_by!(domain: "helixsleep.com")
    visit Rails.application.routes.url_helpers.public_brand_path(brand.slug)

    within("[data-testid='sponsored-shows']") do
      expect(page).to have_link(podcast.title)
      expect(page).to have_css(".chip", text: "Code TIM")
      expect(page).to have_text("use code TIM for 20% off all mattress orders")
    end
  end
end
