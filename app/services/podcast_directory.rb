# The public directory's query (/podcasts and the category pages): a search, filters, a sort and capped offset paging
# over the listed podcasts. Built from request params; anything it doesn't know is ignored, so a crafted URL can only
# narrow the list.
#
#   directory = PodcastDirectory.new(params, category: "Technology")
#   directory.podcasts # this page's podcasts, with their artwork preloaded
#   directory.next_page? / directory.page
class PodcastDirectory
  PER_PAGE = 24
  # Offset paging stops here (spec L3: a cap), so a crawler can't walk the table page by page.
  MAX_PAGE = 20
  # Downloads per episode, the bands owners may choose to show (spec L5): param => range.
  SIZES = { "0-500" => 0...500, "500-1000" => 500...1_000, "1000-2500" => 1_000...2_500, "2500-5000" => 2_500...5_000,
            "5000-10000" => 5_000...10_000, "10000" => 10_000.. }.freeze
  SIZE_LABELS = { "0-500" => "Under 500", "500-1000" => "500 to 1,000", "1000-2500" => "1,000 to 2,500",
                  "2500-5000" => "2,500 to 5,000", "5000-10000" => "5,000 to 10,000", "10000" => "10,000 and up" }.freeze
  # The most a brand wants to pay per spot, in dollars.
  PRICES = [ 100, 250, 500, 1_000, 2_500 ].freeze
  # The size filter and sort read downloads_per_episode: verified Spotify and Apple plays, or the show's own downloads.
  SIZE_LABEL = "Plays or downloads per episode".freeze
  SORTS = { "relevance" => "Best match", "newest" => "Newest episode", "downloads" => "Most plays or downloads" }.freeze
  TOGGLES = %w[open verified sponsored].freeze
  QUERY_LIMIT = 100

  attr_reader :query, :category, :language, :size, :price, :sort, :page

  def initialize(params = {}, category: nil)
    params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
    params = params.with_indifferent_access
    @query = params[:q].to_s.squish.first(QUERY_LIMIT)
    # A category page fixes its category (its links keep it in the path); the directory takes one as a filter.
    @fixed_category = category.present?
    @category = category || params[:category].to_s.strip.first(100).presence
    @language = params[:language].to_s.downcase[/\A[a-z]{2,3}\z/]
    @size = params[:size].to_s.presence_in(SIZES.keys)
    @price = params[:price].to_i.presence_in(PRICES)
    @toggles = TOGGLES.select { |name| params[name].to_s == "1" }
    @sort = params[:sort].to_s.presence_in(SORTS.keys) || default_sort
    @sort = default_sort if @sort == "relevance" && query.empty?
    @page = params[:page].to_i.clamp(1, MAX_PAGE)
  end

  def search? = query.present?
  def open? = @toggles.include?("open")
  def verified? = @toggles.include?("verified")
  def sponsored? = @toggles.include?("sponsored")

  # Any filter beyond the search and the category a category page is for.
  def filtered? = [ (category unless @fixed_category), language, size, price, *@toggles ].any?

  # Only the first page of a plain listing is worth indexing; searches, filters and later pages are noindex.
  def plain? = !search? && !filtered? && page == 1 && sort == default_sort

  def podcasts
    @podcasts ||= begin
      rows = scope.offset((page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
      @next_page = rows.size > PER_PAGE && page < MAX_PAGE
      rows.first(PER_PAGE)
    end
  end

  def next_page?
    podcasts
    @next_page
  end

  def previous_page? = page > 1

  def sort_options = search? ? SORTS : SORTS.except("relevance")

  # The params that make this listing, for links that change one of them (page: 2, sort: "newest", open: nil).
  def to_params(**changes)
    { q: query.presence, category: (@category unless @fixed_category), language: language, size: size, price: price,
      sort: (sort unless sort == default_sort), page: (page if page > 1),
      **@toggles.to_h { |name| [ name.to_sym, "1" ] } }.merge(changes).compact_blank
  end

  private

  def default_sort = search? ? "relevance" : "newest"

  def scope
    relation = Podcast.listed.for_cards.strict_loading
    relation = relation.search_catalog(query) if search? # lane L1's search, best match first
    relation = relation.in_category(category) if category
    relation = relation.in_language(language) if language
    relation = relation.where(downloads_per_episode: SIZES.fetch(size)) if size
    relation = relation.where(min_price_cents: ..(price * 100)) if price
    relation = relation.open_to_sponsors if open?
    relation = relation.claimed.where(verified_readings.arel.exists) if verified?
    relation = relation.where(SponsorMention.where("sponsor_mentions.podcast_id = podcasts.id").arel.exists) if sponsored?
    ordered(relation)
  end

  # Podcast#stats_verified? as SQL: a fresh verified reading of the podcast's own, as the page header counts it.
  def verified_readings
    StatReading.unexpired.trust_verified.where("stat_readings.podcast_id = podcasts.id")
  end

  def ordered(relation)
    case sort
    when "relevance" then relation
    when "downloads"
      relation.reorder(Arel.sql("podcasts.downloads_per_episode DESC NULLS LAST"),
                       Arel.sql("podcasts.last_published_at DESC NULLS LAST"), :id)
    else relation.reorder(Arel.sql("podcasts.last_published_at DESC NULLS LAST"), :id)
    end
  end
end
