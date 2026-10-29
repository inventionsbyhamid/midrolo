require "rails_helper"

# The catalog's share images (og:image): a podcast, an episode, the directory, a category and a brand page, drawn from
# what is stored (never a fetch), public and cacheable. Each page links its card with ?v=<version>; that URL is cached
# for a month, since a change to the card makes a new one. A page's version and its image's version must agree, or
# the link would never get the long cache.
RSpec.describe "Catalog share images" do
  let(:podcast) do
    create(:podcast, :indexable, :with_artwork, title: "Darknet Diaries", author: "Jack Rhysider",
                                                categories: [ "Technology" ], episode_count: 3)
  end
  let(:episode) { create(:episode, podcast: podcast, title: "The Stuxnet Story", duration_seconds: 3_000) }
  let(:brand) { create(:brand, name: "ThreatLocker") }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    2.times { create(:podcast, :indexable, :with_artwork, categories: [ "Technology" ]) }
    create(:sponsor_mention, episode: episode, brand: brand)
  end

  def page = Nokogiri::HTML(response.body)

  def og_image = page.at_css("meta[property='og:image']")["content"]

  def expect_card
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/png")
    expect(Vips::Image.new_from_buffer(response.body, "").then { |image| [ image.width, image.height ] }).to eq([ 1200, 630 ])
    expect(response.body.b).not_to eq(Rails.root.join("app/assets/images/og.png").binread.b)
  end

  {
    "podcast" => [ -> { "/podcasts/#{podcast.slug}" }, %r{/podcasts/darknet-diaries[\w-]*/og\.png\?v=\h{12}\z} ],
    "episode" => [ -> { "/podcasts/#{podcast.slug}/episodes/#{episode.slug}" }, %r{/episodes/[\w-]+/og\.png\?v=\h{12}\z} ],
    "directory" => [ -> { "/podcasts" }, %r{/podcasts/og\.png\?v=\h{12}\z} ],
    "category" => [ -> { "/podcasts/category/technology" }, %r{/podcasts/category/technology/og\.png\?v=\h{12}\z} ],
    "brand" => [ -> { "/brands/#{brand.slug}" }, %r{/brands/[\w-]+/og\.png\?v=\h{12}\z} ]
  }.each do |name, (path, image)|
    it "links the #{name} page to its own card, which the image route draws and caches for a month at that version" do
      get instance_exec(&path)
      expect(response).to have_http_status(:ok)
      url = og_image
      expect(url).to match(image)
      expect(page.at_css("meta[property='og:image:alt']")["content"]).to be_present

      get url
      expect_card
      expect(response.headers["Cache-Control"]).to include("public", "max-age=#{30.days.to_i}")
      expect(response.headers["Set-Cookie"]).to be_blank

      get url, headers: { "If-None-Match" => response.headers["ETag"] }
      expect(response).to have_http_status(:not_modified)
    end
  end

  it "caches a request without the current version for a day" do
    get "/podcasts/#{podcast.slug}/og.png", params: { v: "000000000000" }

    expect_card
    expect(response.headers["Cache-Control"]).to include("public", "max-age=86400")
  end

  it "links the plain directory's card from a search, which has no version of its own" do
    get "/podcasts", params: { q: "darknet" }

    expect(og_image).to end_with("/podcasts/og.png")
  end

  it "draws a new card once the podcast changes" do
    get "/podcasts/#{podcast.slug}"
    before = og_image

    travel 1.minute
    podcast.update!(open_to_sponsors: true)
    get "/podcasts/#{podcast.slug}"
    expect(og_image).not_to eq(before)
  end

  describe "what has no card" do
    it "is a 404 for an unknown or removed podcast, an unknown episode, category or brand, and a brand with no listed show" do
      removed = create(:podcast, :with_artwork, status: "removed")
      quiet = create(:brand)

      [ "/podcasts/nope/og.png", "/podcasts/#{removed.slug}/og.png", "/podcasts/#{podcast.slug}/episodes/nope/og.png",
        "/podcasts/category/knitting/og.png", "/brands/nope/og.png", "/brands/#{quiet.slug}/og.png" ].each do |path|
        get path
        expect(response).to have_http_status(:not_found), path
      end
    end
  end

  it "never fetches anything while drawing" do
    get "/podcasts/#{podcast.slug}/og.png"
    get "/podcasts/category/technology/og.png"

    expect(a_request(:any, /.*/)).not_to have_been_made
  end
end
