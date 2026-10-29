require "rails_helper"

RSpec.describe SocialMetaHelper do
  def head(html) = Nokogiri::HTML("<head>#{html}</head>")

  def content(doc, attribute, name)
    nodes = doc.css("meta[#{attribute}='#{name}']")
    expect(nodes.size).to eq(1), "expected one #{name}, got #{nodes.size}"
    nodes.first["content"]
  end

  before do
    helper.request.env["PATH_INFO"] = "/pricing"
    helper.request.env["QUERY_STRING"] = "utm_source=x"
  end

  describe "#social_meta" do
    it "writes every Open Graph and Twitter tag once, with absolute URLs and no query string" do
      doc = head(helper.social_meta(title: "Pricing", description: "What it costs."))

      expect(content(doc, "name", "description")).to eq("What it costs.")
      expect(doc.css("link[rel='canonical']").map { |link| link["href"] }).to eq([ "http://test.host/pricing" ])
      expect(content(doc, "property", "og:site_name")).to eq("Midrolo")
      expect(content(doc, "property", "og:type")).to eq("website")
      expect(content(doc, "property", "og:url")).to eq("http://test.host/pricing")
      expect(content(doc, "property", "og:title")).to eq("Pricing")
      expect(content(doc, "property", "og:description")).to eq("What it costs.")
      expect(content(doc, "property", "og:image")).to match(%r{\Ahttp://test\.host/assets/og-\h+\.png\z})
      expect(content(doc, "property", "og:image:width")).to eq("1200")
      expect(content(doc, "property", "og:image:height")).to eq("630")
      expect(content(doc, "property", "og:image:alt")).to be_present
      expect(content(doc, "property", "og:locale")).to eq("en_US")
      expect(content(doc, "name", "twitter:card")).to eq("summary_large_image")
      expect(content(doc, "name", "twitter:title")).to eq("Pricing")
      expect(content(doc, "name", "twitter:description")).to eq("What it costs.")
      expect(content(doc, "name", "twitter:image")).to eq(content(doc, "property", "og:image"))
      expect(content(doc, "name", "twitter:image:alt")).to eq(content(doc, "property", "og:image:alt"))
    end

    it "takes a page's own image, alt text, type and URL, and makes a path absolute" do
      doc = head(helper.social_meta(title: "Kit", description: "D", image: "/k/the-ledger/og.png", image_alt: "The kit",
                                    type: "profile", url: "http://test.host/k/the-ledger"))

      expect(content(doc, "property", "og:image")).to eq("http://test.host/k/the-ledger/og.png")
      expect(content(doc, "property", "og:image:alt")).to eq("The kit")
      expect(content(doc, "property", "og:type")).to eq("profile")
      expect(content(doc, "property", "og:url")).to eq("http://test.host/k/the-ledger")
      expect(doc.at_css("link[rel='canonical']")["href"]).to eq("http://test.host/k/the-ledger")
    end

    it "adds a blog post's article tags (R148): its times as ISO 8601 and one tag per tag" do
      doc = head(helper.social_meta(title: "Post", description: "D", type: "article",
                                    article: { published_time: Time.utc(2026, 11, 2), modified_time: Time.utc(2026, 11, 9),
                                               tags: [ "Pricing", "Media kits" ] }))

      expect(content(doc, "property", "og:type")).to eq("article")
      expect(content(doc, "property", "article:published_time")).to eq("2026-11-02T00:00:00Z")
      expect(content(doc, "property", "article:modified_time")).to eq("2026-11-09T00:00:00Z")
      expect(doc.css("meta[property='article:tag']").map { |tag| tag["content"] }).to eq([ "Pricing", "Media kits" ])
    end

    it "writes no article tags for any other page" do
      doc = head(helper.social_meta(title: "Pricing", description: "D"))

      expect(doc.css("meta[property^='article:']")).to be_empty
    end

    it "uses the page's title (without the site name) by default" do
      helper.content_for(:title, "About")

      expect(content(head(helper.social_meta(description: "D")), "property", "og:title")).to eq("About")
    end

    it "escapes a hostile title and description instead of rendering them as markup" do
      hostile = %("><script>alert(1)</script>)
      html = helper.social_meta(title: hostile, description: "#{hostile} & more")
      doc = head(html)

      expect(doc.css("script")).to be_empty
      expect(html).not_to include("<script>")
      expect(content(doc, "property", "og:title")).to eq(hostile)
      expect(content(doc, "name", "twitter:description")).to eq("#{hostile} & more")
    end
  end

  describe "#private_page_meta" do
    it "asks crawlers to skip the page and gives no share image" do
      doc = head(helper.private_page_meta)

      expect(content(doc, "name", "robots")).to eq("noindex, nofollow")
      expect(doc.css("meta[property^='og:'], meta[name^='twitter:']")).to be_empty
    end
  end
end
