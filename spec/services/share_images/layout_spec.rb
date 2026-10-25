require "rails_helper"

RSpec.describe ShareImages::Layout do
  let(:hostile) { %(</text><script>alert(1)</script><text>) }

  def layout(**fields) = described_class.new(label: "Media kit", title: "The Founder's Ledger", seed: 1, **fields)

  # Strict parsing: the SVG must be well-formed XML, or libvips would refuse it.
  def parse(svg) = Nokogiri::XML(svg) { |config| config.strict }

  def texts(svg) = parse(svg).css("text").map { |node| node.text }

  it "is a 1200x630 SVG with the label, title, subline, stat, tags and note as text" do
    svg = layout(subline: "Hosted by Maya Brandt", stat: [ "4,200", "downloads per episode" ],
                 tags: [ "Personal finance", "Startups" ], note: "Stats as reported by the verified owner.").svg
    root = parse(svg).root

    expect([ root["width"], root["height"], root["viewBox"] ]).to eq([ "1200", "630", "0 0 1200 630" ])
    expect(texts(svg)).to include("Media kit", "The Founder's Ledger", "Hosted by Maya Brandt", "4,200",
                                  "downloads per episode", "Personal finance", "Startups",
                                  "Stats as reported by the verified owner.")
  end

  it "escapes hostile text in every field instead of letting it close the text or add elements" do
    svg = layout(label: hostile, title: hostile, subline: hostile, stat: [ hostile, hostile ], tags: [ hostile ],
                 note: "#{hostile} & \"quotes\"").svg
    doc = parse(svg)

    expect(doc.css("script")).to be_empty
    expect(svg).not_to include("<script>")
    expect(doc.css("text").map(&:text).join).to include(hostile, "& \"quotes\"")
  end

  it "drops control characters, which XML forbids" do
    svg = layout(title: "Bell\u0007 and \u0000null\u001B title").svg

    expect(texts(svg)).to include("Bell and null title")
  end

  it "fits a long title in two lines, the second ending in an ellipsis, each within the column" do
    title = "The extraordinarily long-winded podcast about everything that ever happened in the history of " \
            "independent audio, told slowly"
    node = parse(layout(title: title).svg).at_css("[data-role='title']")
    lines = node.css("tspan").map(&:text)

    expect(lines.size).to eq(2)
    expect(lines.last).to end_with("…")
    expect(lines.join(" ").delete_suffix("…")).to satisfy { |shown| title.start_with?(shown.strip) }
    lines.each do |line|
      width = ShareImages::Renderer.text_width(line, family: "ArchivoWide", weight: 800, size: node["font-size"].to_i)
      expect(width).to be <= described_class::TEXT_WIDTH
    end
  end

  it "sets a title that fits in two lines as large as it can" do
    short = parse(layout(title: "Ledger").svg).at_css("[data-role='title']")
    long = parse(layout(title: "The Founder's Ledger: money lessons for first-time founders").svg).at_css("[data-role='title']")

    expect(short["font-size"]).to eq("64")
    expect(long["font-size"].to_i).to be < 64
    expect(long.css("tspan").map(&:text).join(" ")).to eq("The Founder's Ledger: money lessons for first-time founders")
  end

  it "breaks a single word too long for the column" do
    lines = parse(layout(title: "A" * 120).svg).css("[data-role='title'] tspan").map(&:text)

    expect(lines.size).to eq(2)
    expect(lines.last).to end_with("…")
  end

  it "keeps the tags to three different ones, and shortens a long one" do
    tags = [ "One", "Two", "two", "Three", "Four" ]
    expect(parse(layout(tags: tags).svg).css("[data-role='tag'] text").map(&:text)).to eq(%w[One Two Three])

    long = parse(layout(tags: [ "x" * 200 ]).svg).at_css("[data-role='tag'] text").text
    expect(long).to end_with("…")
    expect(long.length).to be < 60
  end

  it "keeps the facts with a short title instead of leaving a band between them" do
    doc = parse(layout(title: "Ledger", subline: "Not affiliated with the show.", stat: [ "18", "brand matches" ],
                       tags: [ "One" ]).svg)
    subline = doc.at_css("[data-role='subline']")["y"].to_f
    stat = doc.at_css("[data-role='stat']")["y"].to_f
    tags_bottom = doc.at_css("[data-role='tag'] rect").then { |rect| rect["y"].to_f + rect["height"].to_f }

    expect(stat - subline).to be <= 72
    expect(tags_bottom).to be <= described_class::DETAILS_BOTTOM
  end

  it "keeps a tall card's facts clear of the waveform" do
    doc = parse(layout(title: "The Founder's Ledger, a long title for two lines", subline: "Hosted by Maya Brandt",
                       stat: [ "4,200", "downloads per episode" ], note: "Stats as reported by the verified owner.",
                       tags: %w[One Two Three], artwork: :image).svg)
    tags_bottom = doc.at_css("[data-role='tag'] rect").then { |rect| rect["y"].to_f + rect["height"].to_f }

    expect(tags_bottom).to be <= described_class::DETAILS_BOTTOM
  end

  describe "the artwork place" do
    it "has none without artwork" do
      doc = parse(layout.svg)
      expect(doc.at_css("#artwork-frame, #artwork-fallback")).to be_nil
    end

    it "frames the picture the renderer lays on top" do
      expect(parse(layout(artwork: :image).svg).at_css("#artwork-frame")).to be_present
    end

    it "draws the mark when the artwork couldn't be fetched" do
      expect(parse(layout(artwork: :fallback).svg).at_css("#artwork-fallback")).to be_present
    end
  end
end
