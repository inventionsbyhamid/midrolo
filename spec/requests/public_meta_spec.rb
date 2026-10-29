require "rails_helper"

# Release check for search and sharing: every public page type, walked as a visitor, has one title of its own, a
# description, a canonical URL, every Open Graph and Twitter tag once with absolute URLs, a 1200x630 share image that
# loads, and JSON-LD where it is planned (the home page, catalog pages and the blog). Pages the pages lane keeps out of search say
# "noindex, follow"; the rest say nothing.
RSpec.describe "Public pages' meta tags", :blog_posts do
  around { |example| with_billing_env { example.run } }

  let(:podcast) do
    create(:podcast, :indexable, :with_artwork, title: "Darknet Diaries", author: "Jack Rhysider", categories: [ "Technology" ],
                                                description: "True stories from the dark side of the internet.", episode_count: 3)
  end
  let(:episode) { create(:episode, podcast: podcast, title: "The Stuxnet Story", description: "A worm that broke centrifuges.") }
  let(:brand) { create(:brand, name: "ThreatLocker") }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    2.times { |i| create(:podcast, :indexable, :with_artwork, title: "Security Show #{i}", categories: [ "Technology" ], description: "About security.") }
    create(:sponsor_mention, episode: episode, brand: brand, promo_code: "DARKNET")
    owner = User.find_or_create_by!(email: User::SAMPLES_EMAIL)
    create(:report, show: create(:show, user: owner, title: "The Founder's Ledger"), kind: "agent", status: "done",
                    sample_slug: first_sample_slug, spend_bucket: "sample")
  end

  def doc = Nokogiri::HTML(response.body)

  # path => whether the page must carry JSON-LD.
  def public_pages
    { "/" => true, "/pricing" => false, "/about" => false, "/privacy" => false, "/terms" => false,
      "/data-sources" => false, "/users/sign_in" => false, "/samples" => false, "/samples/#{first_sample_slug}" => false,
      "/blog" => true, "/blog/#{Blog::Post.published.first.slug}" => true, "/podcasts" => false,
      "/podcasts/#{podcast.slug}" => true, "/podcasts/#{podcast.slug}/episodes/#{episode.slug}" => true,
      "/podcasts/category/technology" => true, "/brands/#{brand.slug}" => true }
  end

  it "gives every public page its own title and description, a canonical URL, the share tags and a share image that loads",
     :aggregate_failures do
    seen = public_pages.map do |path, json_ld|
      get path, params: { utm_source: "newsletter" }
      expect(response).to have_http_status(:ok), path

      page = doc
      tags = share_tags(page)
      title = page.css("title").map(&:text)
      expect(title.size).to eq(1), "#{path}: #{title.size} titles"
      expect(title.first).to include("Midrolo"), "#{path}: title #{title.first.inspect}"
      ShareTags::REQUIRED.each { |key| expect(tags[key].size).to eq(1), "#{path}: #{tags[key].size} #{key}" }
      expect(tags["description"].first.to_s.length).to be_between(50, 200), "#{path}: description #{tags['description'].inspect}"
      expect(page.css("link[rel='canonical']").map { |link| link["href"] }).to eq([ "http://www.example.com#{path}" ]), path
      expect(tags["og:url"]).to eq([ "http://www.example.com#{path}" ]), path
      expect(tags["twitter:card"]).to eq([ "summary_large_image" ]), path
      expect(tags["twitter:image"]).to eq(tags["og:image"]), path
      expect(page.css("script[type='application/ld+json']")).to be_present, "#{path}: no JSON-LD" if json_ld
      expect(tags["robots"]).to be_empty, "#{path}: robots #{tags['robots'].inspect}"

      image = tags["og:image"].first
      expect(image).to start_with("http://www.example.com/"), "#{path}: #{image}"
      get image
      expect(response).to have_http_status(:ok), "#{path}: #{image} answered #{response.status}"
      expect(response.media_type).to eq("image/png"), "#{path}: #{image}"
      expect(Vips::Image.new_from_buffer(response.body, "").then { |png| [ png.width, png.height ] }).to eq([ 1200, 630 ]), image

      [ title.first, tags["description"].first ]
    end

    expect(seen.map(&:first).tally.select { |_, count| count > 1 }.keys).to be_empty
    expect(seen.map(&:last).tally.select { |_, count| count > 1 }.keys).to be_empty
  end

  it "describes Midrolo on the home page: an Organization with its logo, and a WebSite that searches the directory" do
    podcast
    get "/"
    scripts = doc.css("script[type='application/ld+json']")
    expect(scripts.size).to eq(1)
    expect(scripts.first["nonce"]).to be_present
    data = JSON.parse(scripts.first.text)
    expect(data["@context"]).to eq("https://schema.org")
    organization, website = data["@graph"].values_at(0, 1)

    expect(organization).to include("@type" => "Organization", "name" => "Midrolo", "url" => "http://www.example.com/",
                                    "@id" => "http://www.example.com/#organization")
    expect(organization["logo"]).to include("@type" => "ImageObject", "url" => "http://www.example.com/icon-512.png")
    expect(Rails.public_path.join("icon-512.png")).to exist

    expect(website).to include("@type" => "WebSite", "name" => "Midrolo", "url" => "http://www.example.com/",
                               "publisher" => { "@id" => organization["@id"] })
    action = website["potentialAction"]
    expect(action).to include("@type" => "SearchAction", "query-input" => "required name=search_term_string")
    template = action.dig("target", "urlTemplate")
    expect(template).to eq("http://www.example.com/podcasts?q={search_term_string}")

    get template.sub("{search_term_string}", "darknet")
    expect(response).to have_http_status(:ok)
    expect(doc.at_css("h1")).to be_present
    expect(response.body).to include("Darknet Diaries")
  end

  it "lists every indexable page type in the sitemaps, each answering 200 without noindex, and nothing thin or private" do
    thin = create(:podcast, :active, title: "Brand New Show", indexable: false)
    xml = ->(url) { get(url) && Nokogiri::XML(response.body).remove_namespaces! }

    urls = xml.call("/sitemap.xml").css("sitemap loc").flat_map { |part| xml.call(part.text).css("url loc").map(&:text) }
    expect(urls).to include(*public_pages.keys.excluding("/users/sign_in").map { |path| "http://www.example.com#{path}" })
    expect(urls).not_to include("http://www.example.com/podcasts/#{thin.slug}")
    expect(urls.grep(%r{/(admin|shows|account|brand/|inbox|conversations|users)})).to be_empty

    urls.each do |url|
      get url
      expect(response).to have_http_status(:ok), url
      expect(response.headers["X-Robots-Tag"]).to be_nil, url
      expect(share_tags(doc)["robots"]).to be_empty, url
    end
  end

  it "keeps thin catalog pages out of search with noindex, follow and an X-Robots-Tag, and still gives them share tags" do
    thin = create(:podcast, :active, title: "Brand New Show", indexable: false)

    [ "/podcasts/#{thin.slug}", "/podcasts?q=darknet", "/podcasts/category/technology?open=1" ].each do |path|
      get path
      expect(share_tags(doc)["robots"]).to eq([ "noindex, follow" ]), path
      expect(response.headers["X-Robots-Tag"]).to eq("noindex"), path
      expect(share_tags(doc)["og:image"].size).to eq(1), path
    end
  end
end
