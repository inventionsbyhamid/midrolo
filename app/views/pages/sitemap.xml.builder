# The public pages, the done sample reports and the published media kits (R78).
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
end
