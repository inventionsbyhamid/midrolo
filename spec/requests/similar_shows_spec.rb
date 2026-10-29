require "rails_helper"

# Build spec L8 on the report pages: the shows with a similar audience (Qloo, matched to the catalog), the brands that
# already sponsor them, and that proof on the matching sponsor's row. Qloo similar shows are for signed-in people only
# (section 10), so a public sample shows a visitor a sign in prompt instead.
RSpec.describe "Similar shows on reports" do
  let(:user) { create(:user, :subscribed) }
  let(:show) { create(:show, user: user, title: "The Founder's Ledger") }
  let(:mornings) { create(:podcast, :active, title: "Index Fund Mornings", author: "Theo Park") }
  let(:dispatch) { create(:podcast, title: "Dollar Dispatch", status: "pending") }
  let(:notion) { create(:brand, name: "Notion") }
  let(:similar) do
    [ { "qloo_entity_id" => "q1", "name" => "Index Fund Mornings", "score" => 0.9, "podcast_id" => mornings.id },
      { "qloo_entity_id" => "q2", "name" => "Dollar Dispatch", "score" => 0.8, "podcast_id" => dispatch.id },
      { "qloo_entity_id" => "q3", "name" => "Not In The Catalog", "score" => 0.7, "podcast_id" => nil } ]
  end
  let(:report) { create(:report, show: show, kind: "agent", status: "done", similar_podcasts: similar) }

  before do
    create(:sponsor_mention, brand: notion, episode: create(:episode, podcast: mornings, published_at: 2.days.ago))
    create(:sponsor_match, report: report, name: "Notion", brand_entity_id: "q-notion", position: 1)
    create(:sponsor_match, report: report, name: "Fieldnote Coffee", position: 2)
  end

  def page = Nokogiri::HTML(response.body)

  def row(name) = page.css(".match-row").find { |node| node.at_css(".match-name").text == name }

  describe "the owner's report" do
    before { sign_in user }

    it "lists the shows, linked once in the catalog, with their sponsors and the brands that sponsor shows like it" do
      get show_report_path(show, report)

      section = page.at_css("#report_similar")
      expect(section.at_css("h2").text).to eq("Shows with a similar audience")
      expect(section.text).to include("Taste data from Qloo")
      shows = section.css("[data-similar-show]")
      expect(shows.map { |node| node.at_css("p.font-semibold").text.squish })
        .to eq([ "Index Fund Mornings", "Dollar Dispatch", "Not In The Catalog" ])
      expect(shows[0].at_css("a")["href"]).to eq("/podcasts/#{mornings.slug}")
      expect(shows[0].at_css("[data-similar-sponsors]").text.squish).to eq("Sponsored by Notion")
      expect(shows[1].text).to include("Being added to Midrolo")
      expect(shows[2].css("a")).to be_empty

      brands = section.at_css("[data-similar-brands]")
      expect(section.text).to include("Brands that already sponsor shows like yours")
      expect(brands.text.squish).to eq("Notion sponsored 1 episode of Index Fund Mornings")
      expect(brands.at_css("a")["href"]).to eq("/brands/#{notion.slug}")
    end

    it "puts the proof on the sponsor's match: a chip, Why it fits and the proven filter" do
      get show_report_path(show, report)

      notion_row = row("Notion")
      expect(notion_row.css(".match-chips li").map { |chip| chip.text.squish })
        .to eq([ "Shares 3 tastes", "Sponsors 1 show with your audience" ])
      proof = notion_row.at_css("[data-similar-proof]")
      expect(proof.at_css("dt").text).to eq("Sponsors shows like yours")
      expect(proof.text.squish).to include("1 episode of Index Fund Mornings")
      expect(page.at_css("li[data-filter-target='item'][data-proven='true'] .match-name").text).to eq("Notion")

      expect(row("Fieldnote Coffee").text).not_to include("with your audience")
    end

    it "hides the section on a finished report without similar shows, and holds its place while one runs" do
      report.update!(similar_podcasts: [])
      get show_report_path(show, report)
      expect(page.at_css("#report_similar")["hidden"]).not_to be_nil

      running = create(:report, show: create(:show, user: user), kind: "snapshot", status: "running")
      get show_report_path(running.show, running)
      expect(page.at_css("#report_similar .skeleton")).to be_present
    end
  end

  describe "a public sample" do
    let(:owner) { User.find_or_create_by!(email: User::SAMPLES_EMAIL) }
    let(:show) { create(:show, user: owner, title: "The Founder's Ledger") }

    before { report.update!(sample_slug: Samples.slugs[0], spend_bucket: "sample") }

    it "asks a visitor to sign in instead of showing Qloo's similar shows or the proof built on them" do
      get "/samples/#{Samples.slugs[0]}"

      section = page.at_css("#report_similar")
      expect(section.text).to include("Sign in to see the shows whose listeners share this audience's tastes")
      expect(section.at_css("a[href='/users/sign_in']")).to be_present
      expect(response.body).not_to include("Index Fund Mornings", "Sponsors 1 show")
      expect(page.at_css("[data-similar-proof]")).to be_nil
    end

    it "shows them to a signed-in person, in the third person" do
      sign_in create(:user)
      get "/samples/#{Samples.slugs[0]}"

      expect(page.at_css("#report_similar").text).to include("Index Fund Mornings", "Brands that already sponsor shows like this one")
      expect(row("Notion").at_css(".match-chips").text).to include("Sponsors 1 show with this audience")
    end
  end
end
