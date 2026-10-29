require "rails_helper"

# The verified stats flow in a real browser (build spec section 11): the owner opens Stats, follows the Spotify steps,
# presses "I've invited Midrolo", and once Midrolo's sync reads the show (Stats::PlatformFetch stubbed with a
# hand-written result) sees the verified numbers, the audience and what brands see; then disconnects.
RSpec.describe "Verified stats" do
  include Warden::Test::Helpers

  let(:user) { create(:user) }
  let(:workspace) { create(:show, user: user, title: "The Founder's Ledger", verified_at: Time.current) }

  before do
    workspace.podcast.update!(claimed_at: Time.current)
    create(:service_session, platform: "spotify")
    create(:episode, podcast: workspace.podcast, published_at: 5.days.ago)
    login_as(user, scope: :user)
  end

  it "invites Midrolo, shows the verified numbers with their source and date, and disconnects" do
    visit show_path(workspace)
    click_on "Stats"

    expect(page).to have_css("h1", text: "Stats")
    within("#spotify") do
      expect(page).to have_text("Not connected").and have_text("stats@midrolo.com").and have_text("Analytics")
      fill_in "Your Spotify show link", with: "https://open.spotify.com/show/4rOoJ6Egrf8K2IrywzwOMk?si=abc"
      click_on "I've invited Midrolo"
    end
    expect(page).to have_text("We'll keep checking until the invite is accepted")
    within("#spotify") { expect(page).to have_text("Waiting for access") }
    expect(skipped_heading_levels).to be_empty

    connection = StatConnection.find_by!(provider: "spotify")
    allow(Stats::PlatformFetch).to receive(:call).and_return(spotify_result)
    Stats::SyncJob.perform_now(connection.id)

    visit show_stats_path(workspace)
    within("#spotify") do
      expect(page).to have_text("Connected").and have_text("2,400").and have_text("Followers")
    end
    within("#key-numbers") do
      expect(page).to have_text("Stats verified")
      expect(page).to have_text("Spotify plays per episode, 30 days") # 2,400 streams over the one episode
      expect(page).to have_text("with Spotify for Creators")
      expect(page).to have_text("2,140").and have_text("Spotify listeners, 30 days")
    end
    expect(page).to have_text("Who listens").and have_text("United States")
    expect(skipped_heading_levels).to be_empty
    expect(unlabelled_images).to be_empty

    page.driver.resize(375, 812)
    expect(horizontal_overflow).to eq(0)
    page.driver.resize(1400, 1000)

    within("#spotify") { accept_confirm { click_on "Disconnect" } }
    expect(page).to have_text("Disconnected. To end Midrolo's access too")
    within("#spotify") { expect(page).to have_text("Not connected") }
    expect(page).to have_no_css("#key-numbers")
  end
end
