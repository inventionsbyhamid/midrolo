require "rails_helper"

# The podcast page's two lane L8 partials (lane L3's page renders them with podcast:): Audience and the Qloo similar
# shows, both from the show's latest owner or sample report and both for signed-in people only (build spec section 10).
# Blank otherwise, so the page shows its own note or its SQL similar shows.
RSpec.describe "podcast page partials from the show's report" do
  let(:owner) { create(:user) }
  let(:podcast) { create(:podcast, :active, title: "The Founder's Ledger") }
  let(:mornings) { create(:podcast, :active, title: "Index Fund Mornings", author: "Theo Park") }
  let!(:owner_show) { create(:show, user: owner, podcast: podcast, verified_at: 1.day.ago) }
  let(:report) do
    create(:report, show: owner_show, kind: "agent", status: "done", finished_at: Time.zone.local(2026, 10, 28, 9),
                    audience: { "tags" => [ { "id" => "t1", "name" => "Personal Finance", "score" => 0.9 } ],
                                "brands" => [ { "id" => "b1", "name" => "Fieldnote Coffee", "affinity" => 0.9 },
                                              { "id" => "b2", "name" => "Hidden Brand", "affinity" => 0.8 } ] },
                    demographics: { "age" => { "25_to_29" => 0.3 }, "gender" => { "female" => 0.2 } },
                    heatmap: { "location" => "US", "points" => [ { "lat" => 30.3, "lng" => -97.7, "affinity" => 1.0, "label" => "Austin" } ] },
                    similar_podcasts: [ { "qloo_entity_id" => "q1", "name" => "Not In The Catalog", "score" => 0.95, "podcast_id" => nil },
                                        { "qloo_entity_id" => "q2", "name" => "Index Fund Mornings", "score" => 0.9, "podcast_id" => mornings.id } ])
  end

  before do
    travel_to Time.zone.local(2026, 10, 30, 12)
    create(:media_kit, show: owner_show, hidden_brand_ids: [ "b2" ])
    create(:sponsor_match, report: report, category: "Finance")
    create(:sponsor_match, report: report, category: "Finance")
    create(:sponsor_match, report: report, category: "food_and_beverage")
  end

  def html = Nokogiri::HTML5.fragment(rendered)

  def render_partial(name, signed_in:)
    allow(view).to receive(:user_signed_in?).and_return(signed_in)
    render(partial: "podcasts/#{name}", locals: { podcast: podcast })
  end

  describe "podcasts/_audience" do
    it "shows a signed-in person the report's tastes, leans, places and brand categories, as Qloo's" do
      render_partial("audience", signed_in: true)

      expect(html.text).to include("Taste data from Qloo")
      expect(html.css("[data-taste-chip]").map(&:text)).to eq([ "Personal Finance", "Fieldnote Coffee" ]) # the kit hides one
      expect(html.text).to include("Age and gender", "Where they are: Austin.", "Modeled from Qloo taste data, not measured.")
      expect(html.css("ul[aria-label='Brand categories that fit'] li").map(&:text)).to eq([ "Finance", "Food and Beverage" ])
      expect(html.text).to include("From the show's Midrolo report, Oct 28.")
      expect(html.text).not_to include("affinity")
    end

    it "is blank for a visitor" do
      render_partial("audience", signed_in: false)
      expect(rendered.strip).to be_empty
    end

    it "is blank without a report" do
      report.update!(status: "failed")
      render_partial("audience", signed_in: true)
      expect(rendered.strip).to be_empty
    end
  end

  describe "podcasts/_similar" do
    it "shows a signed-in person the report's similar shows, the catalog's first and linked" do
      render_partial("similar", signed_in: true)

      card = html.at_css("[data-match-similar]")
      expect(card.css("li p.font-semibold").map { |name| name.text.squish }).to eq([ "Index Fund Mornings", "Not In The Catalog" ])
      expect(card.text).to include("Theo Park")
      expect(card.at_css("a")["href"]).to eq("/podcasts/#{mornings.slug}")
      expect(html.text).to include("Similar shows", "Taste data from Qloo")
    end

    it "is blank for a visitor" do
      render_partial("similar", signed_in: false)
      expect(rendered.strip).to be_empty
    end

    it "is blank when the report has no similar shows" do
      report.update!(similar_podcasts: [])
      render_partial("similar", signed_in: true)
      expect(rendered.strip).to be_empty
    end
  end
end
