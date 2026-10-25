require "rails_helper"

RSpec.describe ShareImages::KitCard do
  let(:artwork_url) { "https://cdn.example.com/art.jpg" }
  let(:show) do
    create(:show, title: "The Founder's Ledger", author: "Maya Brandt", downloads_per_episode: 4200,
                  artwork_url: artwork_url)
  end
  let(:kit) { create(:media_kit, :published, show: show) }
  let(:tags) { [ "Personal finance", "Startups", "Stoicism", "Index funds" ].map { |name| { "id" => name, "name" => name } } }
  let(:teal) { Vips::Image.black(240, 240, bands: 3).new_from_image([ 0, 128, 128 ]).bandjoin(255).pngsave_buffer }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    create(:report, show: show, status: "done", audience: { "tags" => tags })
  end

  def card = described_class.new(kit)

  # Each <text>'s words; a title's lines (tspans) joined with a space.
  def texts(svg)
    Nokogiri::XML(svg) { |config| config.strict }.css("text").map do |node|
      node.css("tspan").any? ? node.css("tspan").map(&:text).join(" ") : node.text
    end
  end

  # The colour at the middle of the artwork's place on the drawn card.
  def artwork_centre(png)
    box = ShareImages::Layout::ARTWORK
    Vips::Image.new_from_buffer(png, "").getpoint(box[:x] + box[:size] / 2, box[:y] + box[:size] / 2).first(3).map(&:round)
  end

  it "shows the title, host, self-reported downloads, top three taste tags and the Media kit label" do
    shown = texts(card.layout(artwork: :image).svg)

    expect(shown).to include("Media kit", "The Founder's Ledger", "Hosted by Maya Brandt", "4,200",
                             "downloads per episode", "Personal finance", "Startups", "Stoicism",
                             "Stats self-reported by the verified owner.")
    expect(shown).not_to include("Index funds")
    expect(shown.join(" ")).not_to match(/[\u2013\u2014]/) # no dashes in copy
  end

  it "leaves out the downloads and their note when the owner hasn't given them, and the host when unknown" do
    show.update!(downloads_per_episode: nil, author: nil)
    shown = texts(card.layout(artwork: :image).svg).join(" ")

    expect(shown).not_to include("downloads per episode", "self-reported", "Hosted by")
  end

  it "draws a 1200x630 PNG with the stored artwork in its place, fetching nothing" do
    ShareImages::ArtworkStore.write(artwork_url, teal)
    image = card.draw

    expect(image.complete).to be(true)
    expect(Vips::Image.new_from_buffer(image.png, "").then { |png| [ png.width, png.height ] }).to eq([ 1200, 630 ])
    expect(artwork_centre(image.png)).to eq([ 0, 128, 128 ])
    expect(a_request(:any, /.*/)).not_to have_been_made
  end

  it "falls back to the mark, amber slot in the middle, while no artwork is stored, and says it isn't complete" do
    image = card.draw

    expect(image.complete).to be(false)
    expect(artwork_centre(image.png)).to eq([ 243, 167, 18 ])
    expect(a_request(:any, /.*/)).not_to have_been_made
  end

  it "uses the mark, complete, when the show has no artwork" do
    show.update!(artwork_url: nil)
    image = card.draw

    expect(image.complete).to be(true)
    expect(artwork_centre(image.png)).to eq([ 243, 167, 18 ])
  end

  it "escapes a hostile show title from the feed and still draws" do
    show.update!(title: %(</text><script>alert(1)</script>), author: %(<b onload="x">Host</b>))
    ShareImages::ArtworkStore.write(artwork_url, teal)
    svg = card.layout(artwork: :image).svg

    expect(Nokogiri::XML(svg) { |config| config.strict }.css("script, b")).to be_empty
    expect(texts(svg)).to include(%(Hosted by <b onload="x">Host</b>))
    expect(card.draw.png.b).to start_with("\x89PNG".b)
  end

  it "has a cache key that changes when the kit, the show, its report or its stored artwork changes" do
    keys = [ card.cache_key ]
    travel(1.minute) { kit.update!(headline: "New headline") }
    keys << card.cache_key
    travel(2.minutes) { show.update!(downloads_per_episode: 5000) }
    keys << card.cache_key
    travel(3.minutes) { create(:report, show: show, status: "done", audience: { "tags" => tags.first(1) }) }
    keys << card.cache_key
    ShareImages::ArtworkStore.write(artwork_url, teal)
    keys << card.cache_key

    expect(keys.uniq.size).to eq(5)
    expect(keys).to all(start_with("share_images/"))
  end
end
