# The sitemaps (spec L3): /sitemap.xml is an index of one sitemap per kind of page, each at /sitemaps/:name.xml. Only
# pages worth indexing are listed: the public pages and samples, indexable podcasts and their episodes with a sponsor
# read, categories with enough shows, brands with sponsor reads on an indexable show, and the published blog posts.
# Each URL's lastmod comes from what changes it (the feed's latest episode, the post's date).
#
# The catalog's parts (podcasts, categories, brands) can list tens of thousands of rows, so each is built with plucks in
# batches and kept in Rails.cache with the newest updated_at of the rows it lists: a request serves the cached body
# while that stamp is unchanged, and rebuilds it once the stamp moved, at most every REBUILD_EVERY (code review M8).
class SitemapsController < ApplicationController
  # A sitemap file holds at most 50,000 URLs.
  URL_LIMIT = 50_000
  EPISODE_LIMIT = 20_000
  BATCH = 5_000
  PARTS = %w[pages podcasts categories brands blog].freeze
  CACHED = %w[podcasts categories brands].freeze
  REBUILD_EVERY = 10.minutes
  CACHE_FOR = 1.day

  def index
    @parts = %w[pages podcasts categories brands]
    @parts << "blog" if Blog::Post.published.any?
  end

  def show
    @name = params[:name].to_s
    raise ActiveRecord::RecordNotFound unless PARTS.include?(@name)
    return render xml: cached_part if CACHED.include?(@name)

    send(:"load_#{@name}")
  end

  private

  def any_browser? = true

  # The part's XML from the cache while its rows haven't changed (or it was built under REBUILD_EVERY ago), else
  # built and cached again.
  def cached_part
    key = [ "sitemaps/v1", @name ]
    stamp = part_stamp
    entry = Rails.cache.read(key)
    return entry[:xml] if entry && (entry[:stamp] == stamp || entry[:built_at] > REBUILD_EVERY.ago)

    send(:"load_#{@name}")
    xml = render_to_string(:show, formats: [ :xml ])
    Rails.cache.write(key, { stamp: stamp, built_at: Time.current, xml: xml }, expires_in: CACHE_FOR)
    xml
  end

  # The newest change to what the part lists. Episodes and sponsor reads touch their podcast.
  def part_stamp
    times = [ Podcast.maximum(:updated_at), (Brand.maximum(:updated_at) if @name == "brands") ]
    times.map { |time| time&.utc&.iso8601(6) }.join("/")
  end

  def load_pages
    @samples = Samples.reports
  end

  def load_podcasts
    @podcasts = []
    @episodes = []
    Podcast.indexable.where.not(status: "removed").in_batches(of: BATCH) do |batch|
      rows = batch.pluck(:id, :slug, :last_published_at, :updated_at)
      @podcasts.concat(rows.map { |_id, *columns| columns })
      @episodes.concat(sponsored_episodes(rows.to_h { |id, slug, *| [ id, slug ] })) if @episodes.size < EPISODE_LIMIT
      break if @podcasts.size >= URL_LIMIT
    end
    @podcasts = @podcasts.first(URL_LIMIT)
    @episodes = @episodes.first(EPISODE_LIMIT)
  end

  # [[podcast slug, episode slug, published_at]] of the episodes with a sponsor read, for one batch of podcasts.
  def sponsored_episodes(slugs)
    Episode.where(podcast_id: slugs.keys).where(SponsorMention.where("sponsor_mentions.episode_id = episodes.id").arel.exists)
           .order(:podcast_id, published_at: :desc).pluck(:podcast_id, :slug, :published_at)
           .map { |podcast_id, slug, published_at| [ slugs.fetch(podcast_id), slug, published_at ] }
  end

  # The categories with enough indexable listed shows, counted in SQL.
  def load_categories
    indexable = Podcast.indexable.listed
                       .joins("CROSS JOIN LATERAL jsonb_array_elements_text(podcasts.categories) AS category")
                       .group("category").count
    @categories = Podcast.category_counts.map(&:first).select { |name| indexable.fetch(name, 0) >= CategoriesController::MIN_INDEXABLE }
  end

  def load_brands
    @brands = Brand.joins(sponsor_mentions: :podcast).merge(Podcast.indexable.listed).group("brands.slug")
                   .order("brands.slug").limit(URL_LIMIT).pluck("brands.slug", Arel.sql("MAX(sponsor_mentions.published_at)"))
  end

  def load_blog
    @posts = Blog::Post.published
  end
end
