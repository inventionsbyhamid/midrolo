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

  it "hotlinks the feed's artwork until it is stored, as before, and never a non-http URL" do
    podcast = create(:podcast, artwork_url: "https://img.example.com/art.jpg")
    img = tag_of(helper.podcast_artwork_tag(create(:show, podcast: podcast), class: "size-16"))
    expect(img.attributes.transform_values(&:value)).to include("src" => "https://img.example.com/art.jpg",
                                                                "referrerpolicy" => "no-referrer",
                                                                "class" => "size-16 flex-none rounded-lg object-cover")

    podcast.update!(artwork_url: "javascript:alert(1)")
    expect(tag_of(helper.podcast_artwork_tag(podcast)).name).to eq("span")
  end

  it "shows initials when there's no artwork, also for a directory search result" do
    span = tag_of(helper.podcast_artwork_tag(create(:podcast, title: "The Founder's Ledger"), class: "size-16"))
    expect([ span.name, span.text, span["aria-hidden"] ]).to eq([ "span", "TF", "true" ])

    info = Podcasts::Directories::Fake.new.find("fake-3")
    expect(tag_of(helper.podcast_artwork_tag(info)).text).to eq("CC")
  end

  it "shows initials once stored artwork is suppressed and the feed's is gone" do
    podcast = create(:podcast, artwork_image: create(:image, :with_file, suppressed_at: Time.current))
    expect(tag_of(helper.podcast_artwork_tag(podcast)).name).to eq("span")
  end
end
