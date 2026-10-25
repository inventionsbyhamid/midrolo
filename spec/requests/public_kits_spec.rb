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
      expect(response.body).to include("Stats self-reported by the verified owner.", "4,200", "148", "Weekly",
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

    it "never lists sponsor matches" do
      create(:sponsor_match, report: report, name: "Secret Sponsor Co")
      visit_kit
      expect(response.body).not_to include("Secret Sponsor Co")
    end

    it "carries Open Graph and Twitter tags and stays indexable" do
      visit_kit

      expect(response.body).to include('property="og:title" content="The Founder&#39;s Ledger media kit"',
                                       'property="og:description" content="Plain-English money lessons for first-time founders"',
                                       'property="og:image" content="https://cdn.example.com/art.jpg"',
                                       'name="twitter:card"', "rel=\"canonical\" href=\"http://www.example.com/k/the-founder-s-ledger\"")
      expect(response.body).not_to include("noindex")
      expect(response.headers["X-Robots-Tag"]).to be_nil
    end

    it "uses the uploaded cover for the share image" do
      kit.cover.attach(io: Rails.root.join("spec/fixtures/files/cover.png").open, filename: "cover.png")
      visit_kit

      expect(response.body).to match(%r{property="og:image" content="http://www\.example\.com/rails/active_storage/representations/[^"]+/cover\.png"})
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

      stub_plan(kit_badge?: false)
      visit_kit
      expect(response.body).not_to include("Made with Midrolo")
    end
  end

  it "shows stats and about only when the show has no done report" do
    create(:media_kit, :published, show: show)
    create(:report, show: show, status: "running", audience: audience)
    visit_kit

    expect(response.body).to include("Stats self-reported by the verified owner.", "Every week we sit down")
    expect(response.body).not_to include("Fieldnote Coffee")
    expect(response.body).not_to include("Run a Snapshot")
  end
end
