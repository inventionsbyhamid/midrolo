# The blog's pages (R148): whether the blog is linked at all, dates, the share image URL and the structured data
# (JSON-LD) search engines read. The search and share tags themselves come from SocialMetaHelper.
module BlogHelper
  TITLE = "Blog".freeze
  DESCRIPTION = "Plain guides for independent podcasters: finding sponsors who fit your listeners, pricing an ad read " \
                "and pitching brands. From the team behind Midrolo.".freeze
  FEED_TITLE = "#{APP_NAME} blog".freeze

  # The header, the footer and the sitemap link the blog only once a post is published: an empty blog stays unlisted.
  # A post that doesn't parse is reported and leaves the blog unlinked rather than breaking every marketing page; the
  # blog's own pages still fail, and spec/copy/blog_posts_spec.rb catches it before a deploy.
  def blog_listed?
    Blog::Post.published.any?
  rescue Blog::Post::Invalid => e
    Rails.error.report(e, handled: true)
    false
  end

  def blog_date(date) = tag.time(Blog::Post.long_date(date), datetime: date.iso8601)

  # Absolute, with the card's version, so a link preview fetches the image again after the post changes.
  def blog_post_image_url(post) = blog_post_share_image_url(post.slug, v: ShareImages::BlogCard.new(post).version)

  def blog_feed_link = auto_discovery_link_tag(:atom, blog_feed_url, title: FEED_TITLE)

  # A <script type="application/ld+json">. to_json escapes <, > and & (Rails' default), and json_escape makes sure, so
  # a title can't close the tag. A browser never runs it, but it carries the nonce like every inline script (R116).
  def json_ld(data)
    tag.script(json_escape(data.to_json).html_safe, type: "application/ld+json", nonce: content_security_policy_nonce)
  end

  # The index: a Blog with its posts.
  def blog_json_ld(posts)
    listed = posts.map { |post| blog_posting(post).slice("@type", "headline", "description", "url", "datePublished", "dateModified") }
    json_ld("@context" => "https://schema.org", "@type" => "Blog", "@id" => blog_url, "url" => blog_url,
            "name" => FEED_TITLE, "description" => DESCRIPTION, "inLanguage" => "en", "publisher" => publisher_json_ld,
            "blogPost" => listed)
  end

  # A post: the BlogPosting and its breadcrumb trail (Blog, then the post), as the page shows them.
  def blog_post_json_ld(post, image:)
    json_ld("@context" => "https://schema.org",
            "@graph" => [ blog_posting(post).merge("image" => image, "wordCount" => post.word_count),
                          { "@type" => "BreadcrumbList", "itemListElement" => [
                            { "@type" => "ListItem", "position" => 1, "name" => TITLE, "item" => blog_url },
                            { "@type" => "ListItem", "position" => 2, "name" => post.title, "item" => blog_post_url(post) }
                          ] } ])
  end

  private

  def blog_posting(post)
    url = blog_post_url(post)
    { "@type" => "BlogPosting", "headline" => post.title, "description" => post.description, "url" => url,
      "mainEntityOfPage" => { "@type" => "WebPage", "@id" => url },
      "datePublished" => post.published_at.iso8601, "dateModified" => post.modified_at.iso8601,
      "author" => post.author == APP_NAME ? publisher_json_ld : { "@type" => "Person", "name" => post.author },
      "publisher" => publisher_json_ld, "keywords" => post.tags.presence&.join(", "), "inLanguage" => "en" }.compact
  end

  def publisher_json_ld
    { "@type" => "Organization", "name" => APP_NAME, "url" => root_url,
      "logo" => { "@type" => "ImageObject", "url" => URI.join(root_url, "/icon-512.png").to_s, "width" => 512, "height" => 512 } }
  end
end
