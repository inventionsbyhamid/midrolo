require "rails_helper"

# Request a spot in a real browser (build spec L7): a brand asks a claimed show for a midroll, the owner finds it in
# the inbox, accepts and replies (the reply lands through a Turbo Stream), and the brand reads the answer. Mail jobs
# run inline, so both emails go out on the way.
RSpec.describe "Request a spot" do
  include Warden::Test::Helpers

  around do |example|
    adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    Capybara.using_wait_time(10) { example.run }
  ensure
    ActiveJob::Base.queue_adapter = adapter
  end

  let(:owner) { create(:user, name: "Maya Brandt", email: "maya@example.com") }
  let!(:podcast) { claimed_podcast(owner: owner, title: "The Founder's Ledger") }
  let(:asker) { create(:user, name: "Sam Rivera", email: "sam@fieldnote.example") }
  let!(:membership) do
    brand_member_for(asker, brand: create(:brand, name: "Fieldnote Coffee", domain: "fieldnote.example"), verified: true)
  end

  before { ActionMailer::Base.deliveries.clear }
  after { Warden.test_reset! }

  def sign_in_as(user)
    logout(:user)
    login_as(user, scope: :user)
  end

  it "goes from a brand's request to the podcaster's reply and back" do
    month = Date.current.next_month
    sign_in_as(asker)
    visit new_conversation_path(podcast: podcast.slug)

    select "Midroll", from: "Spot"
    check month.strftime("%b %Y")
    fill_in "Budget in US dollars", with: "600"
    fill_in "Message", with: "We roast coffee for people who work from home. A midroll next month?"
    click_button "Send request"

    expect(page).to have_text("Request sent.")
    expect(page).to have_css("h1", text: "The Founder's Ledger")
    expect(page).to have_text("We roast coffee for people who work from home.")
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([ [ "maya@example.com" ] ])

    sign_in_as(owner)
    visit inbox_path
    click_link "Fieldnote Coffee"

    expect(page).to have_text("New request.")
    expect(page).to have_text("Midroll")
    expect(page).to have_text("$600")
    expect(page).not_to have_text("Unverified brand")
    click_button "Accept"
    expect(page).to have_text("You accepted this request.")

    fill_in "Reply", with: "Happy to. Our listeners love good coffee."
    click_button "Send"
    within("ol[aria-label='Messages']") { expect(page).to have_text("Happy to. Our listeners love good coffee.") }
    expect(page).to have_field("Reply", with: "")

    sign_in_as(asker)
    visit brand_inbox_path
    click_link "The Founder's Ledger"
    expect(page).to have_text("Accepted.")
    expect(page).to have_text("Maya, The Founder's Ledger")
    expect(page).to have_text("Happy to. Our listeners love good coffee.")
  end

  # UX review PP-1: a similar show with a long title in the Qloo list (signed in only) once widened the whole page.
  # The hero's Request a spot is the real control (PP-2): for a brand member it opens the form, and the sidebar's
  # button opens the same one.
  it "fits a phone with a long similar title, and the hero's Request a spot opens the form", :aggregate_failures do
    podcast.update!(status: "active", last_published_at: 3.days.ago)
    long = create(:podcast, :active, title: "#{'Late Night Conversations With Teachers and Students ' * 3}".strip.first(120))
    report = create(:report, show: podcast.owner_show, status: "done", finished_at: 1.hour.ago)
    report.update_columns(similar_podcasts: [ { "name" => long.title, "podcast_id" => long.id, "score" => 0.9 },
                                              { "name" => "A Show The Catalog Lacks With A Long Name " * 3, "score" => 0.5 } ])
    sign_in_as(asker)

    { "phone" => [ 390, 844 ], "desktop" => [ 1440, 900 ] }.each do |name, (w, h)|
      page.driver.resize(w, h)
      visit podcast_path(podcast)
      expect(page).to have_css("[data-match-similar] a", text: long.title.first(20))
      expect(evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true), "#{name} scrolls sideways"
    end

    within(".pod-hero") { click_button "Request a spot" }
    expect(page).to have_css("dialog[open]", text: "Request a spot on The Founder's Ledger")
  end
end
