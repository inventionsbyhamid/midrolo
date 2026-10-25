require "rails_helper"

# The whole media kit flow in a real browser: edit the kit, upload a host photo (the test storage service), verify
# ownership with the emailed code, publish, and open the public page, then check phone width and print styles.
RSpec.describe "Media kit" do
  include ActiveJob::TestHelper
  include Warden::Test::Helpers

  let(:user) { create(:user) }
  let(:podcast) do # not :show, which the failure screenshot helper calls
    create(:show, user: user, title: "The Founder's Ledger", author: "Maya Brandt", owner_email: "maya@example.com",
                  downloads_per_episode: 4200, episode_count: 148, cadence_days: 7, categories: %w[Business Finance])
  end
  let(:audience) do
    { "brands" => [ { "id" => "b1", "name" => "Fieldnote Coffee", "affinity" => 0.91 },
                    { "id" => "b2", "name" => "Rival Pods", "affinity" => 0.84 } ],
      "tags" => [ { "id" => "t1", "name" => "Personal finance", "score" => 0.8 } ] }
  end
  let(:heatmap) do
    { "location" => "US", "country" => "US",
      "points" => [ { "lat" => 40.7, "lng" => -74.0, "affinity" => 0.9, "label" => "New York" },
                    { "lat" => 37.8, "lng" => -122.4, "affinity" => 0.7, "label" => "San Francisco" } ] }
  end

  # Every step is a full page load (uploads, image variants, redirects), which can outlast Capybara's 2-second
  # default while the whole suite runs.
  around { |example| Capybara.using_wait_time(10) { example.run } }

  before do
    create(:report, show: podcast, kind: "snapshot", status: "done", audience: audience, heatmap: heatmap)
    login_as(user, scope: :user)
    page.driver.browser.url_blacklist = [ %r{cdn\.jsdelivr\.net} ] # no MapLibre: the Top metros list stands alone
  end

  def horizontal_overflow = evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")

  # Retries a script until it returns true (an image variant is processed on first request, slowly under load).
  def eventually_true(script)
    page.document.synchronize { evaluate_script(script) || raise(Capybara::ExpectationNotMet, script) }
  end

  def computed(selector, property)
    evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json})).getPropertyValue(#{property.to_json})")
  end

  it "edits the kit, uploads a host photo, verifies, publishes and shows the public page without the watermark" do
    visit edit_show_media_kit_path(podcast)
    fill_in "Headline", with: "Plain-English money lessons for first-time founders"
    fill_in "About the show", with: "Every week a founder walks us through their first big money decision."
    attach_file "Host photo", Rails.root.join("spec/fixtures/files/host.jpg")
    check "Hide Rival Pods"
    click_button "Save kit"
    expect(page).to have_text("Kit saved.")
    expect(podcast.media_kit.host_photo).to be_attached

    click_link "Preview", match: :first
    expect(page).to have_css(".kit-watermark", text: "Preview")
    expect(page).to have_text("Plain-English money lessons")

    visit edit_show_media_kit_path(podcast)
    expect(page).to have_text("Verify you own this show to publish.")
    click_link "Verify ownership"
    click_button "Email me a code"
    expect(page).to have_text("We sent a 6-digit code to m***@example.com")
    perform_enqueued_jobs
    code = ActionMailer::Base.deliveries.last.text_part.body.to_s[/\b\d{6}\b/]

    fill_in "6-digit code", with: code
    click_button "Verify"
    expect(page).to have_text("You're verified.")

    click_button "Publish kit"
    expect(page).to have_text("Published.")

    visit public_kit_path(podcast.reload.slug)
    expect(page).to have_css("h1", text: "The Founder's Ledger")
    expect(page).to have_text("Stats self-reported by the verified owner.")
    expect(page).to have_text("Fieldnote Coffee")
    expect(page).to have_no_text("Rival Pods")
    expect(page).to have_no_css(".kit-watermark")
    expect(page).to have_no_text("Preview")
    expect(page).to have_css("img.kit-host-photo")
    expect(eventually_true("document.querySelector('img.kit-host-photo').naturalWidth > 0")).to be(true) # the variant was made
  end

  context "with a published kit" do
    before do
      podcast.verify!
      create(:media_kit, :published, show: podcast, rate_card_overrides: { "midroll" => 150 })
      podcast.update!(contact_email: "sponsors@example.com")
    end

    it "fits a phone screen" do
      page.driver.resize(375, 812)
      visit public_kit_path(podcast.slug)
      expect(page).to have_css("h1", text: "The Founder's Ledger")
      expect(horizontal_overflow).to eq(0)

      visit show_media_kit_path(podcast)
      expect(page).to have_css(".kit-watermark")
      expect(horizontal_overflow).to eq(0)

      visit edit_show_media_kit_path(podcast)
      expect(page).to have_field("Headline")
      expect(horizontal_overflow).to eq(0)
    end

    it "prints without buttons or the map canvas, keeping the top metros and the contact address" do
      visit public_kit_path(podcast.slug)
      expect(page).to have_css("[data-top-metros]", text: "New York")

      execute_script("window.print = () => { window.printed = true }")
      click_button "Print or save as PDF"
      expect(evaluate_script("window.printed")).to be(true)

      page.driver.browser.page.command("Emulation.setEmulatedMedia", media: "print")
      expect(computed("[data-controller='print']", "display")).to eq("none")
      expect(computed(".kit-contact-button", "display")).to eq("none")
      expect(computed(".kit-map .map-frame", "display")).to eq("none")
      expect(computed("[data-top-metros]", "display")).not_to eq("none")
      expect(computed(".kit-contact-address", "display")).not_to eq("none")
      expect(computed(".kit-rates", "break-inside")).to eq("avoid")
    ensure
      page.driver.browser.page.command("Emulation.setEmulatedMedia", media: "")
    end
  end
end
