require "rails_helper"

RSpec.describe "reports/sections/_audience" do
  def entity(name, affinity, image_url: nil)
    { "id" => "id-#{name.parameterize}", "name" => name, "image_url" => image_url, "affinity" => affinity,
      "popularity" => 0.5, "website" => nil }
  end

  let(:audience) do
    { "brands" => [ entity("Fieldnote Coffee", 0.91), entity("Northbound Packs", 0.74), entity("Lumen Sleep", 0.6),
                    entity("Tidewater Tapes", 0.5) ],
      "artists" => [ entity("Phoebe Bridgers", 0.66), entity("Ivy Calder", 0.6) ],
      "tv_shows" => [ entity("The Bear", 0.71), entity("Cold Water", 0.5) ],
      "podcasts" => [ entity("Acquired", 0.88), entity("Shipping Soon", 0.8), entity("Study Hall", 0.7) ],
      "tags" => [ { "id" => "t1", "name" => "Personal Finance", "score" => 0.93 }, { "id" => "t2", "name" => "Slow Travel", "score" => 0.41 },
                  { "id" => "t3", "name" => "Cycling", "score" => 0.4 } ] }
  end
  let(:report) { create(:report, kind: "agent", status: "done", audience: audience) }

  def html = Nokogiri::HTML5.fragment(rendered)

  def render_section = render(partial: "reports/sections/audience", locals: { report: report, read_only: false })

  def chips = html.css(".taste-chips [data-taste-chip]").map(&:text)

  it "shows at most 8 top tastes as chips, mixed across kinds and grouped, with no scores" do
    render_section
    expect(chips.size).to eq(8)
    groups = html.css(".taste-chip-group").to_h { |group| [ group.at_css("dt").text, group.css("[data-taste-chip]").map(&:text) ] }
    expect(groups).to eq("Interests" => [ "Personal Finance", "Slow Travel" ], "Brands" => [ "Fieldnote Coffee", "Northbound Packs" ],
                         "Podcasts" => [ "Acquired", "Shipping Soon" ], "TV" => [ "The Bear" ], "Music" => [ "Phoebe Bridgers" ])
    expect(html.at_css(".taste-chips").text).not_to match(/\d/)
  end

  it "keeps every list behind a collapsed See all tastes, with each score in plain words" do
    render_section
    details = html.at_css("details.taste-more")
    expect(details["open"]).to be_nil
    expect(details.at_css("summary").text.squish).to eq("See all tastes")
    lists = details.css(".taste-list-group").to_h { |group| [ group.at_css("h3").text, group.css("[data-item-name]").map(&:text) ] }
    expect(lists.keys).to eq([ "Interests", "Brands", "Podcasts", "TV", "Music" ])
    expect(lists["Brands"]).to eq([ "Fieldnote Coffee", "Northbound Packs", "Lumen Sleep", "Tidewater Tapes" ])

    first = details.css(".taste-list-group")[1].at_css("li")
    expect(first.text.squish).to eq("Fieldnote Coffee Far more than most")
    expect(details.text).not_to include("0.91", "affinity", "Affinity")
  end

  it "says the tastes come from Qloo taste data, about people with these tastes" do
    render_section
    expect(html.at_css(".report-section-note").text.squish)
      .to eq("What people with your listeners' tastes love more than most people do, from Qloo taste data.")
  end

  it "shows only the interests on a snapshot" do
    report.update!(kind: "snapshot", audience: { "tags" => audience["tags"] })
    render_section
    expect(html.css(".taste-chip-group dt").map(&:text)).to eq([ "Interests" ])
    expect(chips).to eq([ "Personal Finance", "Slow Travel", "Cycling" ])
  end

  it "speaks in the third person on a public sample (R78)" do
    render(partial: "reports/sections/audience", locals: { report: report, read_only: true })
    expect(html.at_css("h2").text).to eq("This show's audience")
    expect(html.text).not_to include("your")
  end

  it "shows a skeleton while the run is going" do
    report.update!(status: "running", audience: nil)
    render_section
    expect(html.css(".skeleton")).to be_present
  end
end
