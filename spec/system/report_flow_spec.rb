require "rails_helper"

# The whole path on Fake providers with JavaScript: sign in, add a show, run the full report (fake LLM mode uses
# the scripted runner with templated reasons), then read the sections. Jobs run inline, so the report is finished
# when the redirect lands; live Turbo updates are covered by the request and model specs.
#
# The map needs MapLibre from cdn.jsdelivr.net and a WebGL context, so this spec needs network access (the
# map style itself is inlined). It is tagged :network; SKIP_NETWORK=1 leaves it out.
RSpec.describe "Report flow", :network do
  # A one-layer style: no tile downloads, and nothing heavy for software WebGL to draw under load.
  blank_style = "data:application/json,#{ERB::Util.url_encode({ version: 8, sources: {},
                                                                layers: [ { id: "bg", type: "background" } ] }.to_json)}"

  around do |example|
    adapter = ActiveJob::Base.queue_adapter
    style = ENV["MAP_STYLE_URL"]
    ActiveJob::Base.queue_adapter = :inline
    ENV["MAP_STYLE_URL"] = blank_style
    example.run
  ensure
    ActiveJob::Base.queue_adapter = adapter
    ENV["MAP_STYLE_URL"] = style
  end

  before do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = mock_google_auth
    # A new account during the hackathon promo gets one full report (spec §11).
    AppSettings.set(:promo_pro_until, 1.week.from_now.to_date.to_s)
  end

  after { OmniAuth.config.mock_auth[:google_oauth2] = nil }

  # Filtering sets the hidden attribute, so the selectors say what is shown. Matching with visible: :all also
  # skips Capybara's per-node visibility round trips, which are slow while the map renders in software.
  def card(filter = "") = "[data-filter-target='item']#{filter}"

  def count_cards(filter = "") = all(card(filter), visible: :all).size

  it "runs a full report and shows At a glance, the steps, the map and filterable sponsor matches" do
    # Page loads and the debounced search can outlast Capybara's 2-second default under load.
    visit "/users/sign_in"
    click_button "Continue with Google"

    fill_in "Podcast title", with: "Founder", wait: 10
    within("#search_results") { click_button "This is my show", wait: 10 }
    click_link "Skip for now", wait: 10
    click_button "Run full report", wait: 10

    expect(page).to have_text("Report ready", wait: 30) # the job runs inside the POST
    expect(page).to have_no_css("aside") # a finished report has no steps rail (R99)
    within("#report_summary") { expect(page).to have_css("ul.glance > li", count: 3) }

    within("#report_how") do
      find("summary", text: "Show the seeds, steps and method").click
      expect(page).to have_text("Building your audience's taste profile…")
      expect(page).to have_text("Saving your sponsor matches…")
      within("#report_seeds") { expect(page).to have_text(/Built from (your show on Qloo|shows and topics like yours)/) }
    end
    within("#report_leans") { expect(page).to have_text(/modeled from Qloo taste data/i) }

    within("#report_audience") do
      expect(page).to have_css("[data-taste-chip]", maximum: 8)
      expect(page).to have_no_css(".taste-list-group")
      find("summary", text: "See all tastes").click
      expect(page).to have_css(".taste-list-group li", minimum: 1)
    end

    scroll_to(find("#report_map"), align: :center) # the map loads MapLibre once it nears the viewport
    expect(page).to have_css("#report_map canvas.maplibregl-canvas", wait: 30)
    expect(page).to have_css("#report_map [data-map-target='status']", visible: :hidden, wait: 30) # the heatmap drew
    map_box = evaluate_script("document.querySelector('#report_map .maplibregl-map').getBoundingClientRect().toJSON()")
    expect(map_box["height"]).to be > 200 # MapLibre's own CSS must not collapse the map
    expect(page).to have_css("head link[rel='stylesheet'][href*='maplibre-gl.css']", visible: :all, count: 1) # linked lazily
    within("#report_map") { expect(page).to have_text("Top places:") }

    total = count_cards
    proven = count_cards("[data-proven='true']")
    expect(total).to be >= 20
    expect(proven).to be_between(1, total - 1) # the fake run has proven sponsors and unproven ones

    # The filters show only with the full list (R99).
    expect(page).to have_no_button("Proven sponsors")
    find("details.match-more > summary").click
    click_button "Proven sponsors"
    expect(page).to have_css("button[aria-pressed='true']", text: "Proven sponsors")
    expect(page).to have_css(card(":not([hidden])"), count: proven, visible: :all)
    expect(page).to have_no_css(card("[data-proven='false']:not([hidden])"), visible: :all)
    expect(page).to have_text("Showing #{proven} of #{total}")

    click_button "Proven sponsors"
    expect(page).to have_css(card(":not([hidden])"), count: total, visible: :all)
  end
end
