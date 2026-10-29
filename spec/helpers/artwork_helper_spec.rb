require "rails_helper"

RSpec.describe ArtworkHelper do
  def tag_of(html) = Nokogiri::HTML.fragment(html).children.first

  it "renders the stored variant through a storage proxy URL, square and lazy" do
    podcast = create(:podcast, artwork_url: "https://img.example.com/art.jpg", artwork_image: create(:image, :with_file))
    img = tag_of(helper.podcast_artwork_tag(podcast, size: :card, class: "size-24"))

    expect(img.name).to eq("img")
    expect(img["src"]).to include("/rails/active_storage/representations/proxy/")
    expect(img.attributes.transform_values(&:value)).to include("width" => "320", "height" => "320", "alt" => "", "loading" => "lazy")
    expect(img["class"]).to eq("size-24 flex-none rounded-lg object-cover")
  end

  # Code review L3: anyone can add a feed, so its artwork URL would tell its host about every visitor.
  it "never hotlinks the feed's artwork: initials until it is stored" do
    podcast = create(:podcast, title: "Tide Pool", artwork_url: "https://img.example.com/art.jpg")
    tile = tag_of(helper.podcast_artwork_tag(create(:show, podcast: podcast), class: "size-16"))
    expect([ tile.name, tile.text, tile["class"] ]).to eq([ "span", "TP", "size-16 flex flex-none items-center justify-center rounded-lg bg-plum-soft font-bold text-plum" ])
    expect(tile.to_html).not_to include("img.example.com")

    info = Podcasts::Directories::Fake.new.find("fake-3").with(artwork_url: "https://img.example.com/cc.jpg")
    expect(tag_of(helper.podcast_artwork_tag(info)).name).to eq("span")
  end

  it "shows initials when there's no artwork, also for a directory search result" do
    span = tag_of(helper.podcast_artwork_tag(create(:podcast, title: "The Founder's Ledger"), class: "size-16"))
    expect([ span.name, span.text, span["aria-hidden"] ]).to eq([ "span", "TF", "true" ])

    info = Podcasts::Directories::Fake.new.find("fake-3")
    expect(tag_of(helper.podcast_artwork_tag(info)).text).to eq("CC")
  end

  it "shows initials once stored artwork is suppressed, even while the feed still names it" do
    podcast = create(:podcast, artwork_url: "https://img.example.com/art.jpg",
                               artwork_image: create(:image, :with_file, suppressed_at: Time.current))
    expect(tag_of(helper.podcast_artwork_tag(podcast)).name).to eq("span")
  end
end
