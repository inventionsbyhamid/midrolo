# One sitemap of the index (SitemapsController#show): the URLs of one kind of page, each with its lastmod when known.
xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.urlset xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  entry = lambda do |loc, lastmod = nil|
    xml.url do
      xml.loc loc
      xml.lastmod lastmod.to_date.iso8601 if lastmod
    end
  end

  case @name
  when "pages"
    [ root_url, podcasts_url, pricing_url, samples_url, about_url, data_sources_url, privacy_url, terms_url ].each { |url| entry.call(url) }
    @samples.each { |sample| entry.call(sample_url(sample.sample_slug), sample.finished_at) }
  when "podcasts"
    @podcasts.each { |slug, published_at, updated_at| entry.call(podcast_url(slug), published_at || updated_at) }
    @episodes.each { |slug, episode_slug, published_at| entry.call(podcast_episode_url(slug, episode_slug), published_at) }
  when "categories"
    @categories.each { |name| entry.call(podcast_category_url(Podcast.category_slug(name))) }
  when "brands"
    @brands.each { |slug, last_seen| entry.call(public_brand_url(slug), last_seen) }
  when "blog"
    if @posts.any?
      entry.call(blog_url, @posts.map(&:modified_on).max)
      @posts.each { |post| entry.call(blog_post_url(post), post.modified_on) }
    end
  end
end
