require "rails_helper"

# A brand's main flow in a real browser on the Fake taste provider and fake LLM mode: sign in from the brand
# workspace, say who the brand is, run a fit search (jobs run inline, so it is done when its page loads), read the
# ranked shows with their reasons, proof and price, save one, and find it on the saved list.
RSpec.describe "Brand fit search" do
  around do |example|
    adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    Capybara.using_wait_time(10) { example.run }
  ensure
    ActiveJob::Base.queue_adapter = adapter
  end

  before do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = mock_google_auth(email: "ada@notion.so", name: "Ada Brand")
    allow(Llm).to receive(:mode).and_return(:fake)
    Taste::Provider.reset!
    allow(Sponsors::History).to receive(:for_brand).and_return([])
    create(:podcast, :active, title: "The Founder's Ledger", qloo_entity_id: "fake:podcast:the-founder-s-ledger",
                              categories: [ "Business" ], open_to_sponsors: true, claimed_at: 1.day.ago, min_price_cents: 30_000,
                              downloads_per_episode: 1800, downloads_trust: "verified")
    create(:podcast, :active, title: "Deep Work Daily", qloo_entity_id: "fake:podcast:deep-work-daily", categories: [ "Business" ])
  end

  after { OmniAuth.config.mock_auth[:google_oauth2] = nil }

  it "onboards a brand, runs a search, reads the results and saves a show" do
    visit "/brand"
    click_button "Continue with Google"

    expect(page).to have_css("h1", text: "Find podcasts your customers love")
    fill_in "Brand name", with: "Notion"
    fill_in "Website", with: "notion.so"
    click_button "Continue"

    expect(page).to have_text("Run your first search below")
    expect(page).to have_field("Brand to search for", with: "Notion")
    fill_in "Budget per episode, in US dollars", with: "500"
    click_button "Find podcasts"

    expect(page).to have_text("2 shows ranked for you")
    expect(page).to have_text("Taste data from Qloo")
    within("#result_podcast_#{Podcast.find_by!(title: "The Founder's Ledger").public_id}") do
      expect(page).to have_text("Qloo ranks it #")
      expect(page).to have_text("From $300 per episode")
      expect(page).to have_text("Within your budget")
      expect(page).to have_link("Request a spot")
      click_button "Save"
      expect(page).to have_button("Saved")
    end

    find("summary", text: "How the agent searched").click
    expect(page).to have_text("Finding Notion on Qloo…")
    expect(page).to have_text("Writing your brief…")

    click_link "Saved", match: :first
    expect(page).to have_css("h1", text: "Saved shows")
    expect(page).to have_link("The Founder's Ledger")
  end
end
