require "rails_helper"

# The accessibility pass on the signed-in marketplace screens, in a real browser at 375px and 1440px (the public catalog
# pages have their own in public_catalog_spec): the brand workspace (dashboard, a new search, fit results, saved
# shows), the claim page, the stats screen and both inboxes with a conversation. Each has one main landmark and one h1,
# headings that go down a level at a time, labelled images and form fields, AA contrast, no sideways scroll, and a
# visible focus ring.
RSpec.describe "Signed-in screens' accessibility" do
  include Warden::Test::Helpers

  around { |example| Capybara.using_wait_time(10) { example.run } }
  after { Warden.test_reset! }

  let(:owner) { create(:user, name: "Maya Brandt", email: "maya@example.com") }
  let!(:podcast) { claimed_podcast(owner: owner, title: "The Founder's Ledger") }
  let(:asker) { create(:user, name: "Sam Rivera", email: "sam@fieldnote.example") }
  let!(:membership) do
    brand_member_for(asker, brand: create(:brand, name: "Fieldnote Coffee", domain: "fieldnote.example"), verified: true)
  end
  let!(:conversation) { start_request(podcast, membership) }
  let(:unclaimed) { create(:podcast, :indexable, title: "Darknet Diaries", categories: [ "Technology" ]) }

  # Form fields a screen reader would announce with no name.
  def unlabelled_fields
    evaluate_script(<<~JS)
      [...document.querySelectorAll("input:not([type=hidden]):not([type=submit]):not([type=button]), select, textarea")]
        .filter((el) => el.getClientRects().length > 0)
        .filter((el) => !(el.labels && el.labels.length) && !el.getAttribute("aria-label") && !el.getAttribute("aria-labelledby") && !el.title)
        .map((el) => el.outerHTML.slice(0, 100))
    JS
  end

  def main_landmarks = evaluate_script("document.querySelectorAll('main').length")

  # With more than one nav, each needs a name to tell them apart.
  def unnamed_navs
    evaluate_script(<<~JS)
      (() => {
        const navs = [...document.querySelectorAll("nav")].filter((el) => el.getClientRects().length > 0);
        return navs.length < 2 ? [] : navs.filter((el) => !el.getAttribute("aria-label") && !el.getAttribute("aria-labelledby")).map((el) => el.outerHTML.slice(0, 80));
      })()
    JS
  end

  def check_screen(at)
    expect(page).to have_css("h1")
    expect(main_landmarks).to eq(1), "#{at} has #{main_landmarks} main landmarks"
    expect(heading_levels.count(1)).to eq(1), "#{at} has #{heading_levels.count(1)} h1s"
    expect(skipped_heading_levels).to be_empty, "#{at} skips #{skipped_heading_levels.join(', ')}"
    expect(unlabelled_images).to be_empty, "#{at}: #{unlabelled_images.join('; ')}"
    expect(unlabelled_fields).to be_empty, "#{at}: #{unlabelled_fields.join('; ')}"
    expect(unnamed_navs).to be_empty, "#{at}: #{unnamed_navs.join('; ')}"
    expect(contrast_failures).to be_empty, "#{at}: #{contrast_failures.join('; ')}"
    expect(horizontal_overflow).to eq(0), "#{at} scrolls sideways"
  end

  def walk(user, paths)
    login_as(user, scope: :user)
    { "375" => [ 375, 812 ], "1440" => [ 1440, 900 ] }.each do |width, (w, h)|
      page.driver.resize(w, h)
      paths.each do |path|
        visit path
        check_screen("#{path} at #{width}px")
      end
    end
  end

  it "checks the brand side: dashboard, new search, fit results, saved shows, the request form and the inbox", :aggregate_failures do
    search = create(:fit_search, user: asker, brand: membership.brand, status: "done", finished_at: Time.current,
                                 summary: "One.\nTwo.\nThree.")
    create(:fit_result, fit_search: search, podcast: podcast, position: 1, score: 87, price_fit: "within",
                        reasons: [ "Its listeners like coffee." ],
                        proof: { "brands" => [ { "brand" => "Trade Coffee", "relation" => "competitor", "episodes" => 4 } ] })
    create(:saved_podcast, brand: membership.brand, podcast: podcast, user: asker)

    walk(asker, [ "/brand", "/brand/searches/new", "/brand/searches/#{search.public_id}", "/brand/saved",
                  "/conversations/new?podcast=#{unclaimed.slug}", "/brand/inbox", "/conversations/#{conversation.to_param}" ])
  end

  it "checks the podcaster side: the claim page, the stats screen and the inbox", :aggregate_failures do
    walk(owner, [ "/podcasts/#{unclaimed.slug}/claim", "/shows/#{podcast.owner_show.to_param}/stats", "/inbox",
                  "/conversations/#{conversation.to_param}" ])
  end

  it "shows a focus ring on the first thing a keyboard reaches" do
    login_as(asker, scope: :user)
    visit "/brand"
    page.driver.browser.keyboard.type(:tab)

    expect(focus_outline_style).to eq("solid")
  end
end
