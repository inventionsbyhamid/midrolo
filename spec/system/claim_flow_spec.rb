require "rails_helper"

# Lane L4's main flow in a real browser, as the first real user will take it: a Spotify for Creators show whose feed
# lists no owner email. Claim from the claim page, get the line for the show description with Spotify's steps, check
# the feed, then set up the listing and publish it.
RSpec.describe "Claiming a show" do
  include Warden::Test::Helpers

  let(:user) { create(:user, email: "jane@example.com") }
  let(:podcast) do
    create(:podcast, :active, title: "The Founder's Ledger", feed_url: "https://anchor.fm/s/abc123/podcast/rss",
                              categories: [ "Business" ])
  end

  around { |example| Capybara.using_wait_time(10) { example.run } }

  before { login_as(user, scope: :user) }

  def horizontal_overflow = evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")

  it "claims with the line in the show description, then sets up and publishes the listing" do
    stub_claim_feed(podcast.feed_url)

    visit new_podcast_claim_path(podcast)
    expect(page).to have_css("h1", text: "Claim this show")
    click_button "Claim this show"

    expect(page).to have_text("Add this line to your show description")
    expect(page).to have_text("Spotify for Creators")
    token = ShowVerification.last.token_line
    expect(page).to have_css("code", text: token)
    page.driver.resize(375, 812)
    expect(horizontal_overflow).to eq(0)
    page.driver.resize(1400, 1000)

    stub_claim_feed(podcast.feed_url, description: "A show about money. #{token}")
    click_button "Check my feed"

    expect(page).to have_text("You're verified.")
    expect(page).to have_css("h1", text: "Your listing")
    check "Open to sponsors"
    month = Podcast.listing_months.second
    find("#media_kit_open_months_#{month}", visible: :all).click # the chip's checkbox lies over its label
    fill_in "Who you're looking for", with: "Banks for small businesses"
    fill_in "What you won't advertise", with: "Gambling, crypto"
    click_button "Save listing"
    expect(page).to have_text("Saved.")

    click_button "Save and publish"
    expect(page).to have_text("Published.")
    expect(page).to have_link(href: "/podcasts/#{podcast.slug}#rates")

    kit = user.shows.sole.media_kit
    expect(kit).to have_attributes(open_to_sponsors: true, open_months: [ month ], looking_for: "Banks for small businesses",
                                   exclusions: %w[Gambling crypto])
    expect(podcast.reload).to have_attributes(open_to_sponsors: true, claimed_at: be_present)
    expect(podcast.min_price_cents).to be_positive

    visit shows_path
    expect(page).to have_text("Claimed")
  end
end
