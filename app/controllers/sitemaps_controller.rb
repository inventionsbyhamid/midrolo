# The sitemaps (spec L3): /sitemap.xml is an index of one sitemap per kind of page, each at /sitemaps/:name.xml. Only
# pages worth indexing are listed: the public pages and samples, indexable podcasts and their episodes with a sponsor
# read, categories with enough shows, brands with sponsor reads on an indexable show, and the published blog posts.
# Each URL's lastmod comes from what changes it (the feed's latest episode, the post's date).
class SitemapsController < ApplicationController
  # A sitemap file holds at most 50,000 URLs.
  URL_LIMIT = 50_000
  EPISODE_LIMIT = 20_000

  def index
    @parts = %w[pages podcasts categories brands]
    @parts << "blog" if Blog::Post.published.any?
  end

  def show
    @name = params[:name].to_s
    case @name
    when "pages" then load_pages
    when "podcasts" then load_podcasts
    when "categories" then load_categories
    when "brands" then load_brands
    when "blog" then load_blog
    else raise ActiveRecord::RecordNotFound
    end
  end

  private

  def any_browser? = true

  def load_pages
    @samples = Samples.reports
  end

  def load_podcasts
    @podcasts = Podcast.indexable.where.not(status: "removed").order(:slug).limit(URL_LIMIT)
                       .pluck(:slug, :last_published_at, :updated_at)
    @episodes = Episode.joins(:podcast).merge(Podcast.indexable.where.not(status: "removed"))
                       .where(SponsorMention.where("sponsor_mentions.episode_id = episodes.id").arel.exists)
                       .order("podcasts.slug", "episodes.published_at DESC").limit(EPISODE_LIMIT)
                       .pluck("podcasts.slug", "episodes.slug", "episodes.published_at")
  end

  def load_categories
    names = Podcast.category_counts.map(&:first)
    indexable = Podcast.indexable.listed.select(:categories).flat_map(&:categories).tally
    @categories = names.select { |name| indexable.fetch(name, 0) >= CategoriesController::MIN_INDEXABLE }
  end

  def load_brands
    @brands = Brand.joins(sponsor_mentions: :podcast).merge(Podcast.indexable.listed).group("brands.slug")
                   .order("brands.slug").limit(URL_LIMIT).pluck("brands.slug", Arel.sql("MAX(sponsor_mentions.published_at)"))
  end

  def load_blog
    @posts = Blog::Post.published
  end
end
