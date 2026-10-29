module ShareImages
  # A blog post's share image (R148): the post's title (up to three lines, since post titles run longer than show
  # titles), its date and reading time, and its first tags, with the Midrolo logo. No artwork. The waveform comes from
  # the slug, so each post draws its own. The key follows the post file's digest, so any edit draws the card again.
  class BlogCard < Card
    # post is a Blog::Post.
    def initialize(post)
      @post = post
    end

    private

    def key_parts = [ "blog", @post.slug, @post.version ]

    def fields
      { label: "Blog", title: @post.title, title_lines: 3,
        subline: "#{Blog::Post.long_date(@post.published_on)} · #{@post.reading_minutes} min read",
        tags: @post.tags, seed: @post.slug }
    end
  end
end
