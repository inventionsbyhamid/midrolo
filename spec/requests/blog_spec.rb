require "rails_helper"

# The blog (R148): the index, each post with its search and share tags and structured data, the Atom feed, the share
# images, and the links that appear only once a post is published. Posts come from spec/fixtures/blog when an example
# is tagged :blog_posts, else there are none (spec/support/blog_posts.rb).
RSpec.describe "Blog" do
  def page = Nokogiri::HTML(response.body)
  def meta(attribute, name) = page.css("meta[#{attribute}='#{name}']").map { |tag| tag["content"] }
  def json_ld = page.css("script[type='application/ld+json']").map { |script| JSON.parse(script.text) }
  def nav_labels(region) = page.css("#{region} nav a").map { |link| link.text.squish }

  let(:slug) { "finding-your-first-sponsor" }
  let(:url) { "http://www.example.com/blog/#{slug}" }

  describe "GET /blog with no posts" do
    it "says posts are on the way, keeps out of search results and isn't linked anywhere" do
      get "/blog"

      expect(response).to have_http_status(:ok)
      expect(page.at_css("title").text).to eq("Blog | Midrolo")
      expect(page.at_css("h1").text.squish).to eq("Blog")
      expect(page.at_css("main .empty-state").text.squish).to include("Posts are on the way.")
      expect(page.at_css("main .empty-state a[href='/samples']")).to be_present
      expect(page.css(".post-card")).to be_empty
      expect(meta("name", "robots")).to eq([ "noindex, follow" ])
      expect(page.css("a[href='/blog']")).to be_empty # neither the header nor the footer

      get "/"
      expect(page.css("a[href='/blog']")).to be_empty
      expect(nav_labels("header.site-header")).not_to include("Blog")
    end
  end

  describe "GET /blog with posts", :blog_posts do
    it "lists the published posts, newest first, with their date, reading time and tags" do
      get "/blog"

      expect(response).to have_http_status(:ok)
      cards = page.css("main .post-card")
      expect(cards.map { |card| card.at_css("h2 a")["href"] })
        .to eq(%w[/blog/finding-your-first-sponsor /blog/what-to-charge-for-a-midroll /blog/media-kits-brands-read])
      first = cards.first
      expect(first.at_css("h2").text.squish).to eq("Finding your first sponsor when your show is small")
      expect(first.at_css(".post-card-description").text).to start_with("A fixture post for the blog specs.")
      expect(first.at_css("time")["datetime"]).to eq("2026-10-20")
      expect(first.at_css("time").text).to eq("October 20, 2026")
      expect(first.at_css(".post-meta").text.squish).to include("1 min read")
      expect(first.css(".post-tags li").map(&:text)).to eq(%w[Sponsorship Pitching])
      expect(page.text).not_to include("An unfinished draft", "A post scheduled for later")
      expect(meta("name", "robots")).to be_empty
    end

    it "carries its share tags, the feed link and a Blog in JSON-LD" do
      get "/blog", params: { utm_source: "x" }

      expect_share_tags(page, url: "http://www.example.com/blog", image: %r{\Ahttp://www\.example\.com/assets/og-\h+\.png\z})
      expect(meta("property", "og:type")).to eq([ "website" ])
      feed = page.at_css("link[rel='alternate'][type='application/atom+xml']")
      expect(feed["href"]).to eq("http://www.example.com/blog/feed.xml")
      blog = json_ld.sole
      expect(blog).to include("@context" => "https://schema.org", "@type" => "Blog", "url" => "http://www.example.com/blog")
      expect(blog["blogPost"].map { |post| post["url"] }).to eq(%w[finding-your-first-sponsor what-to-charge-for-a-midroll
                                                                    media-kits-brands-read].map { |s| "http://www.example.com/blog/#{s}" })
    end

    it "adds Blog to the header and the footer of the public pages" do
      get "/"

      expect(nav_labels("header.site-header")).to include("Blog")
      expect(page.at_css("header.site-header nav a[href='/blog']")).to be_present
      expect(page.at_css("footer a[href='/blog']").text).to eq("Blog")
    end
  end

  describe "GET /blog/:slug", :blog_posts do
    it "shows the post with its breadcrumb, dates, author, reading time, contents, related posts and call to action" do
      get "/blog/#{slug}"

      expect(response).to have_http_status(:ok)
      expect(page.at_css("title").text).to eq("Finding your first sponsor when your show is small | Midrolo")
      crumbs = page.css("nav[aria-label='Breadcrumb'] li")
      expect(crumbs.map { |crumb| crumb.text.squish }).to eq([ "Blog", "Finding your first sponsor when your show is small" ])
      expect(crumbs.first.at_css("a")["href"]).to eq("/blog")
      expect(crumbs.last["aria-current"]).to eq("page")

      article = page.at_css("main article")
      expect(article.css("h1").map { |h1| h1.text.squish }).to eq([ "Finding your first sponsor when your show is small" ])
      meta_line = article.at_css(".post-meta")
      expect(meta_line.css("time").map { |time| [ time["datetime"], time.text ] })
        .to eq([ %w[2026-10-20 October\ 20,\ 2026], %w[2026-10-25 October\ 25,\ 2026] ])
      expect(meta_line.text.squish).to include("By Midrolo", "Updated October 25, 2026", "1 min read")

      toc = article.at_css("nav.post-toc")
      expect(toc.css("a").map { |link| [ link["href"], link.text ] }).to eq([
        [ "#start-with-brands-your-listeners-use", "Start with brands your listeners use" ],
        [ "#send-a-short-pitch", "Send a short pitch" ], [ "#follow-up-once", "Follow up once" ]
      ])
      toc.css("a").each { |link| expect(article.at_css(".post-prose #{link['href']}")).to be_present }

      related = page.at_css("section.post-related")
      expect(related.at_css("h2").text).to eq("More from the blog")
      expect(related.css("h3 a").map { |link| link["href"] }).to eq(%w[/blog/what-to-charge-for-a-midroll /blog/media-kits-brands-read])

      cta = page.at_css("section.post-cta")
      expect(cta.at_xpath(".//a[normalize-space()='Get my free Snapshot']")["href"]).to eq("/users/sign_in")
      expect(cta.at_xpath(".//a[normalize-space()='See the sample reports']")["href"]).to eq("/samples")
    end

    it "keeps the headings in order: one h1, then h2s with h3s under them" do
      get "/blog/#{slug}"

      levels = page.css("main h1, main h2, main h3, main h4").map { |heading| heading.name[1].to_i }
      expect(levels.first).to eq(1)
      expect(levels.count(1)).to eq(1)
      expect(levels.each_cons(2).select { |a, b| b > a + 1 }).to be_empty
    end

    it "leaves out the contents for a post with fewer than three sections, and names a guest author" do
      get "/blog/what-to-charge-for-a-midroll"

      expect(page.at_css("nav.post-toc")).to be_nil
      expect(page.at_css(".post-meta").text.squish).to include("By Sam Rivera")
      expect(page.at_css(".post-meta").text).not_to include("Updated")
    end

    it "carries article share tags with a canonical URL, the post's own share image and no query string" do
      get "/blog/#{slug}", params: { utm_source: "newsletter" }

      expect_share_tags(page, url: url, image: %r{\Ahttp://www\.example\.com/blog/#{slug}/og\.png\?v=\h{12}\z})
      expect(meta("property", "og:type")).to eq([ "article" ])
      expect(meta("property", "og:title")).to eq([ "Finding your first sponsor when your show is small" ])
      expect(meta("name", "description").first).to start_with("A fixture post for the blog specs.")
      expect(meta("property", "article:published_time")).to eq([ "2026-10-20T00:00:00Z" ])
      expect(meta("property", "article:modified_time")).to eq([ "2026-10-25T00:00:00Z" ])
      expect(meta("property", "article:tag")).to eq(%w[Sponsorship Pitching])
      expect(page.at_css("link[rel='alternate'][type='application/atom+xml']")["href"]).to eq("http://www.example.com/blog/feed.xml")
    end

    it "describes the post as a BlogPosting with a BreadcrumbList in JSON-LD that parses" do
      get "/blog/#{slug}"

      graph = json_ld.sole.fetch("@graph")
      posting = graph.find { |node| node["@type"] == "BlogPosting" }
      expect(posting).to include("headline" => "Finding your first sponsor when your show is small",
                                 "url" => url, "mainEntityOfPage" => { "@type" => "WebPage", "@id" => url },
                                 "datePublished" => "2026-10-20T00:00:00Z", "dateModified" => "2026-10-25T00:00:00Z",
                                 "keywords" => "Sponsorship, Pitching", "image" => meta("property", "og:image").first)
      expect(posting["description"]).to eq(meta("name", "description").first)
      expect(posting["author"]).to include("@type" => "Organization", "name" => "Midrolo")
      expect(posting["publisher"]).to include("@type" => "Organization", "name" => "Midrolo")
      expect(posting.dig("publisher", "logo", "url")).to eq("http://www.example.com/icon-512.png")

      crumbs = graph.find { |node| node["@type"] == "BreadcrumbList" }["itemListElement"]
      expect(crumbs.map { |crumb| crumb.values_at("position", "name", "item") }).to eq([
        [ 1, "Blog", "http://www.example.com/blog" ], [ 2, "Finding your first sponsor when your show is small", url ]
      ])

      get "/blog/what-to-charge-for-a-midroll"
      expect(json_ld.sole["@graph"].first["author"]).to eq("@type" => "Person", "name" => "Sam Rivera")
    end

    it "shows the post body without a dash, as the copy rules ask" do
      get "/blog/#{slug}"

      expect(page.at_css("main").text).not_to match(/[–—]/)
    end

    it "is a 404 for an unknown slug, a draft and a future post outside development, as in production" do
      %w[no-such-post unfinished-draft scheduled-for-later].each do |missing|
        get "/blog/#{missing}"
        expect(response).to have_http_status(:not_found), missing
        get "/blog/#{missing}/og.png"
        expect(response).to have_http_status(:not_found), missing
      end
    end

    it "shows a draft in development, marked so its writer knows visitors can't see it" do
      allow(Rails.env).to receive(:development?).and_return(true)
      get "/blog/unfinished-draft"

      expect(response).to have_http_status(:ok)
      expect(page.at_css(".post-status").text.squish).to eq("Draft, hidden in production")
    end
  end

  describe "GET /blog/feed.xml" do
    def feed = Nokogiri::XML(response.body) { |config| config.strict }
    def atom(node, path) = node.xpath(path, "a" => "http://www.w3.org/2005/Atom")

    it "is a valid Atom feed of the published posts, newest first, with their full text", :blog_posts do
      get "/blog/feed.xml"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/atom+xml")
      doc = feed
      expect(doc.root.name).to eq("feed")
      expect(doc.root.namespace.href).to eq("http://www.w3.org/2005/Atom")
      expect(atom(doc, "/a:feed/a:title").text).to eq("Midrolo blog")
      expect(atom(doc, "/a:feed/a:id").text).to eq("http://www.example.com/blog")
      expect(atom(doc, "/a:feed/a:updated").text).to eq("2026-10-25T00:00:00Z")
      expect(atom(doc, "/a:feed/a:link[@rel='self']").first["href"]).to eq("http://www.example.com/blog/feed.xml")

      entries = atom(doc, "/a:feed/a:entry")
      expect(entries.map { |entry| atom(entry, "a:id").text })
        .to eq(%w[finding-your-first-sponsor what-to-charge-for-a-midroll media-kits-brands-read].map { |s| "http://www.example.com/blog/#{s}" })
      entries.each do |entry|
        %w[a:id a:title a:updated a:published a:summary a:content a:author/a:name].each do |path|
          expect(atom(entry, path).text).to be_present, "an entry lacks #{path}"
        end
        expect(atom(entry, "a:link[@rel='alternate']").first["href"]).to eq(atom(entry, "a:id").text)
      end
      first = entries.first
      expect(atom(first, "a:content").first["type"]).to eq("html")
      expect(atom(first, "a:content").text).to include("<h2 id=\"send-a-short-pitch\">Send a short pitch</h2>")
      expect(atom(first, "a:content").text).not_to include("heading-anchor")
      expect(atom(first, "a:category").map { |category| category["term"] }).to eq(%w[Sponsorship Pitching])

      parsed = Feedjira.parse(response.body)
      expect(parsed.entries.map(&:title).first).to eq("Finding your first sponsor when your show is small")
    end

    it "is a valid, empty feed while there are no posts" do
      get "/blog/feed.xml"

      expect(response).to have_http_status(:ok)
      expect(atom(feed, "/a:feed/a:entry")).to be_empty
      expect(atom(feed, "/a:feed/a:updated").text).to be_present
    end
  end

  describe "GET /blog/:slug/og.png", :blog_posts do
    it "is a 1200x630 PNG, public for a day" do
      get "/blog/#{slug}/og.png"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      image = Vips::Image.new_from_buffer(response.body, "")
      expect([ image.width, image.height ]).to eq([ 1200, 630 ])
      expect(response.body.b).not_to eq(Rails.root.join("app/assets/images/og.png").binread.b)
      expect(response.headers["Cache-Control"]).to include("public", "max-age=86400")
    end
  end

  # The sitemap index (/sitemap.xml) points at one part per kind of page; the blog's is /sitemaps/blog.xml.
  describe "the blog's sitemap" do
    def locs = Nokogiri::XML(response.body).remove_namespaces!.xpath("//url").to_h { |url| [ url.at("loc").text, url.at("lastmod")&.text ] }

    it "lists the blog and each published post with its last change", :blog_posts do
      get "/sitemaps/blog.xml"

      expect(locs).to include("http://www.example.com/blog" => "2026-10-25",
                              "http://www.example.com/blog/finding-your-first-sponsor" => "2026-10-25",
                              "http://www.example.com/blog/what-to-charge-for-a-midroll" => "2026-10-10",
                              "http://www.example.com/blog/media-kits-brands-read" => "2026-10-01")
      expect(locs.keys.grep(/unfinished-draft|scheduled-for-later/)).to be_empty
    end

    it "leaves the blog out while it has no posts" do
      get "/sitemap.xml"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("/sitemaps/pages.xml")
      expect(response.body).not_to include("/sitemaps/blog.xml")
    end
  end

  it "lets crawlers into the blog" do
    get "/robots.txt"

    expect(response.body).not_to match(%r{^Disallow: /blog})
    expect(response.body).to match(%r{^Allow: /$})
  end
end
