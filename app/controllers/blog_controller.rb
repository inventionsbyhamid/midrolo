# The blog (R148), the SEO growth channel: the index of published posts, each post, and the Atom feed. Posts are
# Markdown files in content/blog (Blog::Post); each one's share image is ShareImagesController#blog_post. A draft, a
# post dated in the future and an unknown slug are 404s outside development.
class BlogController < ApplicationController
  layout "marketing"

  def index
    @posts = Blog::Post.published
  end

  def show
    @post = Blog::Post.find!(params[:slug])
    @related = @post.related
  end

  def feed
    @posts = Blog::Post.published
  end

  private

  # Readers, crawlers and feed readers come with all sorts of user agents.
  def any_browser? = true
end
