require "rails_helper"

RSpec.describe "reports/sections/_map" do
  let(:points) do
    [ { "lat" => 40.7, "lng" => -74.0, "affinity" => 0.9, "label" => "New York" },
      { "lat" => 40.8, "lng" => -73.9, "affinity" => 0.5, "label" => "New York" },
      { "lat" => 30.3, "lng" => -97.7, "affinity" => 1.0, "label" => "Austin" },
      { "lat" => 47.6, "lng" => -122.3, "affinity" => 0.3, "label" => "Seattle" },
      { "lat" => 45.5, "lng" => -122.7, "affinity" => 0.2, "label" => nil } ] +
      (1..9).map { |i| { "lat" => 35.0 + i, "lng" => -90.0, "affinity" => 0.1, "label" => "Town #{i}" } }
  end
  let(:report) { create(:report, kind: "agent", status: "done", heatmap: { "location" => "US", "country" => "US", "points" => points }) }

  def html = Nokogiri::HTML5.fragment(rendered)

  def render_section = render(partial: "reports/sections/map", locals: { report: report, read_only: false })

  it "hands the points and the map style to the map controller" do
    render_section
    map = html.at_css("[data-controller~='map']")
    expect(JSON.parse(map["data-map-points-value"])).to eq(points.map { |p| p.slice("lat", "lng", "affinity") })
    expect(map["data-map-style-value"]).to eq("https://tiles.openfreemap.org/styles/positron")
  end

  it "reads the style from MAP_STYLE_URL" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MAP_STYLE_URL").and_return("https://tiles.example.com/style.json")
    render_section
    expect(html.at_css("[data-controller~='map']")["data-map-style-value"]).to eq("https://tiles.example.com/style.json")
  end

  it "ranks the top 8 metros by summed affinity beside the map" do
    render_section
    metros = html.css("[data-top-metros] li").map { |li| li.at_css("[data-metro-name]").text }
    expect(metros).to eq([ "New York", "Austin", "Seattle", "Town 1", "Town 2", "Town 3", "Town 4", "Town 5" ])
  end

  it "names the country and says the map is modeled" do
    render_section
    expect(html.text.squish).to include("United States", "Modeled from Qloo taste data")
  end

  it "names the country for a metros fallback map" do
    report.update!(heatmap: { "location" => "metros", "country" => "GB", "points" => points })
    render_section
    expect(html.text.squish).to include("United Kingdom")
    expect(html.text).not_to include("metros across metros")
  end

  it "shows no place badge and a plain map label when a metros map has no country" do
    report.update!(heatmap: { "location" => "metros", "country" => nil, "points" => points })
    render_section
    expect(html.at_css("#report_map .badge")).to be_nil
    expect(html.text.squish).not_to match(/(?<!Top) metros/) # no orphaned " metros" badge
    expect(html.at_css("[data-controller~='map']")["aria-label"]).to eq("Heatmap of where people with your listeners' tastes live")
  end

  it "hands the controller the pinned MapLibre stylesheet to load with the library" do
    render_section
    expect(html.at_css("[data-controller~='map']")["data-map-stylesheet-value"]).to eq(view.maplibre_stylesheet_url)
  end

  it "shows an empty state with no points" do
    report.update!(heatmap: { "location" => "US", "country" => "US", "points" => [] })
    render_section
    expect(html.text).to include("Not enough location data for this audience")
    expect(html.at_css("[data-controller~='map']")).to be_nil
  end

  it "shows a skeleton while the run is going" do
    report.update!(status: "running", heatmap: nil)
    render_section
    expect(html.css(".skeleton")).to be_present
  end
end
