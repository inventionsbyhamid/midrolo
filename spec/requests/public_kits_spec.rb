require "rails_helper"

RSpec.describe "Public media kits" do
  let(:user) { create(:user) }
  let(:show) do
    create(:show, user: user, title: "The Founder's Ledger", owner_email: "owner@example.com", downloads_per_episode: 4200,
                  episode_count: 148, cadence_days: 7, artwork_url: "https://cdn.example.com/art.jpg")
  end
  let(:audience) do
    { "brands" => [ { "id" => "b1", "name" => "Fieldnote Coffee", "affinity" => 0.91 },
                    { "id" => "b2", "name" => "Rival Pods", "affinity" => 0.84 } ],
      "tags" => [ { "id" => "t1", "name" => "Personal finance", "score" => 0.8 } ] }
  end
  let(:browser) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15" }

  def visit_kit(slug = show.slug, agent: browser) = get(public_kit_path(slug), headers: { "User-Agent" => agent })

  it "404s for an unknown slug" do
    visit_kit("unknown")
    expect(response).to have_http_status(:not_found)
  end

  it "404s for an unpublished kit while the owner's preview still works" do
    create(:media_kit, show: show)
    show.verify!

    visit_kit
    expect(response).to have_http_status(:not_found)

    sign_in user
    get show_media_kit_path(show)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("kit-watermark", "The Founder&#39;s Ledger")
  end

  describe "a published kit" do
    let!(:kit) { create(:media_kit, :published, show: show, hidden_brand_ids: [ "b2" ]) }
    let!(:report) { create(:report, show: show, status: "done", audience: audience) }

    it "shows the kit with the self-reported note and without hidden brands or the watermark" do
      visit_kit

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Stats as reported by the verified owner.", "4,200", "148", "Weekly",
                                       "Fieldnote Coffee", "Personal finance", "Plain-English money lessons")
      expect(response.body).not_to include("Rival Pods")
      expect(response.body).not_to include("kit-watermark")
    end

    it "names the host of the verified RSS feed, and nothing else from its URL" do
      show.update!(feed_url: "https://Feeds.Example.com/shows/ledger.xml?key=s3cret")
      visit_kit

      expect(response.body).to include("Verified owner of the RSS feed at feeds.example.com")
      expect(response.body).not_to include("ledger.xml")
      expect(response.body).not_to include("s3cret")
    end

    it "reads like the report: at most 8 taste chips, every list behind See all tastes, compact leans and top places (R99)" do
      brands = (1..14).map { |i| { "id" => "b#{i}", "name" => "Brand #{i}", "affinity" => 0.9 } }
      tags = (1..12).map { |i| { "id" => "t#{i}", "name" => "Taste #{i}", "score" => 0.8 } }
      podcasts = (1..6).map { |i| { "id" => "p#{i}", "name" => "Pod #{i}", "affinity" => 0.8 } }
      report.update!(audience: { "brands" => brands, "tags" => tags, "podcasts" => podcasts },
                     demographics: { "age" => { "25_to_29" => 0.3, "30_to_34" => -0.2 }, "gender" => { "female" => 0.3 } },
                     heatmap: { "location" => "US", "points" => [ { "lat" => 30.3, "lng" => -97.7, "affinity" => 1.0, "label" => "Austin" },
                                                                 { "lat" => 39.7, "lng" => -105.0, "affinity" => 0.5, "label" => "Denver" } ] })
      show.update!(contact_email: "sponsors@example.com")
      get public_kit_path(show.slug), headers: { "User-Agent" => browser }
      doc = Nokogiri::HTML(response.body)

      chips = doc.css(".taste-chips [data-taste-chip]").map(&:text)
      expect(chips.size).to eq(8)
      expect(chips).not_to include("Brand 2") # hidden by the owner, chips included
      expect(doc.at_css(".taste-chips").text).not_to match(/\d\.\d/)
      more = doc.at_css("details.kit-more")
      expect(more["open"]).to be_nil
      expect(more.at_css("summary").text.squish).to eq("See all tastes")
      brand_names = more.css(".kit-brand-name").map(&:text)
      expect(brand_names).to include("Brand 1", "Brand 13")
      expect(brand_names).not_to include("Brand 2")
      # A printed kit has every list even without JS: a print-only copy outside the closed disclosure.
      expect(doc.at_css(".kit-print-tastes").css(".kit-brand-name").map(&:text)).to eq(brand_names)
      expect(doc.css(".age-bars [data-lean]").size).to eq(2)
      expect(doc.at_css("[data-gender-line]").text.squish).to eq("Gender Leans strongly toward women")
      expect(doc.at_css(".leans-note").text).to eq("Modeled from Qloo taste data, not measured.")
      expect(doc.at_css("[data-top-places]").text.squish).to eq("Top places: Austin and Denver")

      # The report's order (R99): the kit's sections, and within Who listens the tastes, age and gender, then places.
      expect(doc.css(".kit-sheet .kit-h2").map(&:text)).to eq([ "About the show", "Who listens", "Rates", "Work with us" ])
      audience = doc.at_css("[aria-labelledby='kit-audience-title']")
      order = %w[.taste-chips details.kit-more .leans .kit-map].map { |selector| audience.to_html.index(audience.at_css(selector).to_html) }
      expect(order).to eq(order.sort)
      # Brands read the kit, so the map speaks of the audience in the third person (Task 20).
      expect(doc.at_css("figure.map-frame")["aria-label"]).to eq("Heatmap of where people with this audience's tastes live in United States")
    end

    it "never lists sponsor matches" do
      create(:sponsor_match, report: report, name: "Secret Sponsor Co")
      visit_kit
      expect(response.body).not_to include("Secret Sponsor Co")
    end

    it "carries every share tag once, points them at the kit's own share image and stays indexable" do
      visit_kit
      doc = Nokogiri::HTML(response.body)

      expect_share_tags(doc, url: "http://www.example.com/k/the-founder-s-ledger",
                             image: %r{\Ahttp://www\.example\.com/k/the-founder-s-ledger/og\.png\?v=\h{12}\z})
      tags = share_tags(doc)
      expect(tags["og:title"]).to eq([ "The Founder's Ledger media kit" ])
      expect(tags["og:description"]).to eq([ "Plain-English money lessons for first-time founders" ])
      expect(tags["og:image:alt"]).to eq([ "Media kit for The Founder's Ledger" ])
      # The version follows the card, so link previews pick up a changed kit.
      versions = [ tags["og:image"].first ]
      travel(1.minute) { kit.update!(headline: "A new headline") }
      visit_kit
      versions << share_tags(Nokogiri::HTML(response.body))["og:image"].first
      expect(versions.uniq.size).to eq(2)
      expect(response.body).not_to include("noindex")
      expect(response.headers["X-Robots-Tag"]).to be_nil
    end

    it "counts views from visitors but not from the owner or bots" do
      visit_kit
      visit_kit(agent: "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)")
      visit_kit(agent: "facebookexternalhit/1.1")
      visit_kit(agent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/120.0 Safari/537.36")
      expect(kit.reload.views_count).to eq(1)

      sign_in user
      visit_kit
      expect(kit.reload.views_count).to eq(1)
    end

    it "counts a returning visitor once per 30 minutes" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      3.times { visit_kit }
      get public_kit_path(show.slug), headers: { "User-Agent" => browser, "REMOTE_ADDR" => "198.51.100.4" }
      expect(kit.reload.views_count).to eq(2)

      travel 31.minutes
      visit_kit
      expect(kit.reload.views_count).to eq(3)
    end

    it "opens in an older browser, since a brand may use whatever their company provides" do
      visit_kit(agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36")
      expect(response).to have_http_status(:ok)
      expect(kit.reload.views_count).to eq(1)
    end

    it "offers a print button wired to Stimulus, with no inline script" do
      visit_kit
      expect(response.body).to include('data-action="print#print"')
      expect(response.body).not_to match(/onclick=/i)
    end

    describe "Work with us" do
      it "mails the contact email the owner chose" do
        show.update!(contact_email: "sponsors@example.com")
        visit_kit

        expect(response.body).to include('href="mailto:sponsors@example.com?subject=Sponsoring%20The%20Founder%27s%20Ledger"')
        expect(response.body).not_to include("owner@example.com")
      end

      it "links to the show's website when there is no contact email, never to the feed's owner address" do
        show.update!(website: "https://foundersledger.example.com")
        visit_kit

        expect(response.body).to include('href="https://foundersledger.example.com"')
        expect(response.body).not_to include("owner@example.com")
        expect(response.body).not_to include("mailto:")
      end

      it "is left out when there is neither, with no prompt for the owner on the public page" do
        visit_kit
        expect(response.body).not_to include("Work with us")
        expect(response.body).not_to include("Add a contact email")
        expect(response.body).not_to include("owner@example.com")
      end
    end

    it "shows the Made with Midrolo badge only when the plan has one" do
      visit_kit
      expect(response.body).to include("Made with Midrolo")
      badge = Nokogiri::HTML(response.body).at_css(".kit-badge-link img.brand-logo")
      expect(badge["src"]).to match(%r{/assets/brand/mark-\h+\.svg\z})
      expect(badge["alt"]).to eq("")

      stub_plan(kit_badge: false)
      visit_kit
      expect(response.body).not_to include("Made with Midrolo")
    end
  end

  it "shows stats and about only when the show has no done report" do
    create(:media_kit, :published, show: show)
    create(:report, show: show, status: "running", audience: audience)
    visit_kit

    expect(response.body).to include("Stats as reported by the verified owner.", "Every week we sit down")
    expect(response.body).not_to include("Fieldnote Coffee")
    expect(response.body).not_to include("Run a Snapshot")
  end
end
