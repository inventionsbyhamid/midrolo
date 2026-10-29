require "rails_helper"

# Lane L2's main flow in a real browser: new episodes come in, the sponsor scan runs (fake LLM mode, so patterns only),
# and what it found shows on the admin dashboard and, once lane L3 draws its routes, on the podcast and brand pages.
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
    skip "the podcast page arrives with lane L3" unless Rails.application.routes.url_helpers.respond_to?(:podcast_path)

    podcast, episode = scanned
    visit Rails.application.routes.url_helpers.podcast_path(podcast)

    within("[data-testid='sponsor-history']") do
      expect(page).to have_link("Helix Sleep")
      expect(page).to have_css(".badge", text: "Code TIM")
      expect(page).to have_text("This episode is brought to you by AG1.")
      click_link episode.title, match: :first
    end
    expect(page).to have_current_path(%r{/episodes/#{episode.slug}\z})
  end
end
