# The sitemap index: one sitemap per kind of page (SitemapsController).
xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.sitemapindex xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  @parts.each do |name|
    xml.sitemap { xml.loc sitemap_part_url(name) }
  end
end
