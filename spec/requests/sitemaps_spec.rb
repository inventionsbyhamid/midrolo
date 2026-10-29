require "rails_helper"

# The sitemap index and its parts (lane L3), replacing the single sitemap. The public pages, samples and blog stay in.
RSpec.describe "Sitemaps" do
  # A done sample report under the samples owner, at slug (as spec/requests/pages_spec.rb makes one).
  def create_sample(slug)
    owner = User.find_or_create_by!(email: User::SAMPLES_EMAIL)
    create(:report, show: create(:show, user: owner, title: "The Founder's Ledger"), kind: "agent", status: "done",
                    sample_slug: slug, spend_bucket: "sample")
  end

  def locs = Nokogiri::XML(response.body).remove_namespaces!.xpath("//loc").map(&:text)

  it "indexes one sitemap per kind of page, blog included once it has a post", :blog_posts do
    get "/sitemap.xml"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/xml")
    expect(locs).to eq(%w[pages podcasts categories brands blog].map { |name| "http://www.example.com/sitemaps/#{name}.xml" })
  end

  it "lists the public pages and the done samples" do
    create_sample(Samples.slugs[0])
    get "/sitemaps/pages.xml"
    expect(locs).to eq((%w[/ /podcasts /pricing /samples /about /data-sources /privacy /terms] + [ "/samples/#{Samples.slugs[0]}" ])
                         .map { |path| "http://www.example.com#{path}" })
  end

  it "lists indexable podcasts with their latest episode as lastmod, and episodes with a sponsor read" do
    indexable = create(:podcast, :indexable, title: "Darknet Diaries", last_published_at: Time.zone.local(2026, 10, 20))
    create(:podcast, :active, title: "Thin Show")
    create(:podcast, :indexable, title: "Gone Show").remove!
    sponsored = create(:episode, podcast: indexable, title: "Ricky", published_at: Time.zone.local(2026, 10, 1))
    create(:episode, podcast: indexable, title: "No Sponsor")
    create(:sponsor_mention, episode: sponsored)

    get "/sitemaps/podcasts.xml"

    expect(locs).to eq([ "http://www.example.com/podcasts/#{indexable.slug}",
                         "http://www.example.com/podcasts/#{indexable.slug}/episodes/#{sponsored.slug}" ])
    expect(response.body).to include("<lastmod>2026-10-20</lastmod>")
  end

  it "lists categories with enough indexable shows and brands sponsoring an indexable show" do
    3.times { create(:podcast, :indexable, categories: [ "Technology" ]) }
    create(:podcast, :indexable, categories: [ "Comedy" ])
    brand = create(:brand, name: "ThreatLocker")
    create(:sponsor_mention, episode: create(:episode, podcast: Podcast.indexable.first), brand: brand)
    create(:sponsor_mention, episode: create(:episode, podcast: create(:podcast, :active)), brand: create(:brand, name: "Hidden"))

    get "/sitemaps/categories.xml"
    expect(locs).to eq([ "http://www.example.com/podcasts/category/technology" ])

    get "/sitemaps/brands.xml"
    expect(locs).to eq([ "http://www.example.com/brands/#{brand.slug}" ])
  end

  it "lists the published blog posts", :blog_posts do
    get "/sitemaps/blog.xml"
    expect(locs.first).to eq("http://www.example.com/blog")
    expect(locs.size).to eq(Blog::Post.published.size + 1)
  end

  it "404s an unknown part" do
    get "/sitemaps/secrets.xml"
    expect(response).to have_http_status(:not_found)
  end

  it "keeps crawlers out of searches (they can add shows), polls and the removal form, and in the catalog's pages" do
    get "/robots.txt"
    rules = response.body.lines.map(&:strip)
    expect(rules).to include("Disallow: /podcasts?q=", "Disallow: /podcasts?*&q=", "Disallow: /podcasts/adding",
                             "Disallow: /podcasts/*/status", "Disallow: /podcasts/*/sign_in", "Disallow: /podcasts/*/remove")
    expect(rules).not_to include("Disallow: /podcasts", "Disallow: /brands")
  end
end
