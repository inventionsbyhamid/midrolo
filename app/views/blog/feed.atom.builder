# The blog's Atom feed (R148): every published post, newest first, with its full text. Ids are the posts' URLs.
# xml:base lets a feed reader resolve a post's relative links (/samples) against this site.
atom_feed(root_url: blog_url, url: blog_feed_url, id: blog_url, "xml:base" => root_url) do |feed|
  feed.title BlogHelper::FEED_TITLE
  feed.subtitle BlogHelper::DESCRIPTION
  feed.updated @posts.map(&:modified_at).max # now, while there are no posts
  feed.icon URI.join(root_url, "/icon-512.png").to_s
  feed.author do |author|
    author.name APP_NAME
    author.uri root_url
  end

  @posts.each do |post|
    url = blog_post_url(post)
    feed.entry(post, id: url, url: url, published: post.published_at, updated: post.modified_at) do |entry|
      entry.title post.title
      entry.summary post.description
      entry.content post.feed_html, type: "html"
      entry.author { |author| author.name post.author }
      post.tags.each { |name| entry.category term: name }
    end
  end
end
