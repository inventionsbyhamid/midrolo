# The public pages, the done sample reports, the published media kits (R78) and the published blog posts (R148). The
# blog's index is listed only once it has a post.
xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.urlset xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  [ root_url, pricing_url, samples_url, about_url, privacy_url, terms_url ].each do |url|
    xml.url { xml.loc url }
  end
  @samples.each do |sample|
    xml.url do
      xml.loc sample_url(sample.sample_slug)
      xml.lastmod sample.finished_at.to_date.iso8601 if sample.finished_at
    end
  end
  @kit_slugs.each { |slug| xml.url { xml.loc public_kit_url(slug) } }
  if @posts.any?
    xml.url do
      xml.loc blog_url
      xml.lastmod @posts.map(&:modified_on).max.iso8601
    end
    @posts.each do |post|
      xml.url do
        xml.loc blog_post_url(post)
        xml.lastmod post.modified_on.iso8601
      end
    end
  end
end
