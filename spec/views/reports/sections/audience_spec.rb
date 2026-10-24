require "rails_helper"

RSpec.describe "reports/sections/_audience" do
  def entity(name, affinity, image_url: nil)
    { "id" => "id-#{name.parameterize}", "name" => name, "image_url" => image_url, "affinity" => affinity,
      "popularity" => 0.5, "website" => nil }
  end

  let(:audience) do
    { "brands" => [ entity("Fieldnote Coffee", 0.91, image_url: "https://images.example.com/fieldnote.png"), entity("Northbound Packs", 0.74) ],
      "artists" => [ entity("Phoebe Bridgers", 0.66) ],
      "tv_shows" => [ entity("The Bear", 0.71) ],
      "podcasts" => [ entity("Acquired", 0.88) ],
      "tags" => [ { "id" => "t1", "name" => "Personal Finance", "score" => 0.93 }, { "id" => "t2", "name" => "Slow Travel", "score" => 0.41 } ] }
  end
  let(:report) { create(:report, kind: "agent", status: "done", audience: audience) }

  def html = Nokogiri::HTML5.fragment(rendered)

  def render_section = render(partial: "reports/sections/audience", locals: { report: report })

  it "renders accessible tabs for brands, music, TV, podcasts and taste tags" do
    render_section
    tablist = html.at_css("[role='tablist']")
    tabs = tablist.css("[role='tab']")
    expect(tabs.map { |t| t.text.squish }).to eq([ "Brands", "Music", "TV", "Podcasts", "Taste tags" ])
    expect(tabs.map { |t| t["aria-selected"] }).to eq(%w[true false false false false])

    tabs.each do |tab|
      panel = html.at_css("##{tab['aria-controls']}")
      expect(panel["role"]).to eq("tabpanel")
      expect(panel["aria-labelledby"]).to eq(tab["id"])
    end
    expect(html.css("[role='tabpanel']").map { |p| p["hidden"].nil? }).to eq([ true, false, false, false, false ])
  end

  it "shows each item with its image or initials and an affinity meter" do
    render_section
    brands = html.css("[role='tabpanel']").first.css("li")
    expect(brands.first.at_css("img")["src"]).to eq("https://images.example.com/fieldnote.png")
    expect(brands.first.at_css("img")["onerror"]).to be_nil
    expect(brands.first.at_css("img")["data-action"]).to eq("error->logo#fallback")
    expect(brands.last.text).to include("NP", "Northbound Packs")
    expect(brands.first.at_css("[role='meter']")["aria-valuenow"]).to eq("91")

    tags = html.css("[role='tabpanel']").last.css("li")
    expect(tags.map { |li| li.at_css("[data-item-name]").text }).to eq([ "Personal Finance", "Slow Travel" ])
    expect(tags.first.at_css("[role='meter']")["aria-valuenow"]).to eq("93")
  end

  it "skips a list that came back empty" do
    audience["artists"] = []
    render_section
    expect(html.css("[role='tab']").map { |t| t.text.squish }).to eq([ "Brands", "TV", "Podcasts", "Taste tags" ])
  end

  it "shows only the taste tags tab on a snapshot" do
    report.update!(kind: "snapshot", audience: { "tags" => audience["tags"] })
    render_section
    expect(html.css("[role='tab']").map { |t| t.text.squish }).to eq([ "Taste tags" ])
    expect(html.css("[role='tabpanel']").first["hidden"]).to be_nil
  end

  it "never renders an image from a non-http URL" do
    audience["brands"][0]["image_url"] = "javascript:alert(1)"
    render_section
    expect(rendered).not_to include("javascript:")
  end

  it "shows a skeleton while the run is going" do
    report.update!(status: "running", audience: nil)
    render_section
    expect(html.css(".skeleton")).to be_present
  end
end
