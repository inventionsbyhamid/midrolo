# The public catalog (spec L3): the directory with search, filters and sort at /podcasts, and each podcast's page at
# /podcasts/:slug. A search the catalog can't answer well asks the outside directory (Catalog::LazyAdd), which adds the
# missing shows as pending; the results page shows them as "Adding this show" and reloads them (adding) until their
# feeds are read. A pending podcast's own page does the same through status.
class PodcastsController < ApplicationController
  include CatalogPage

  # A search may reach the outside directory, so it has a bucket of its own (on top of the global one).
  throttle to: 20, within: 1.minute, by: :user_or_ip, scope: "podcast_search", only: :index, if: -> { params[:q].present? }
  # The two polls run every few seconds for at most MAX_POLLS rounds.
  throttle to: 40, within: 1.minute, by: :user_or_ip, scope: "podcast_polls", only: %i[adding status]

  ADDING_LIMIT = 5
  MAX_POLLS = 40
  POLL_DELAY = 3_000
  EPISODE_LIMIT = 50

  helper_method :page_episodes

  def index
    @directory = PodcastDirectory.new(params)
    @podcasts = @directory.podcasts
    @adding = @directory.search? && @directory.page == 1 ? lazy_add : []
    @sponsor_counts = sponsor_counts(@podcasts + @adding)
    noindex! unless @directory.plain?
  end

  # GET /podcasts/search/adding?ids=a,b&n=2: the "Adding this show" cards for those podcasts, polled until none is pending.
  def adding
    noindex!
    ids = params[:ids].to_s.split(",").map(&:strip).compact_blank.first(ADDING_LIMIT)
    @adding = Podcast.for_cards.where(public_id: ids).where.not(status: "removed").in_order_of(:public_id, ids).to_a
    @poll = params[:n].to_i.clamp(1, MAX_POLLS)
    @sponsor_counts = sponsor_counts(@adding)
  end

  def show
    @podcast = find_podcast(Podcast.for_page.strict_loading) { |slug| podcast_path(slug) } or return
    return render_removed if @podcast.removed?

    noindex! unless @podcast.page_indexable?
    return if fresh_for_visitors(etag: page_etag, last_modified: @podcast.updated_at)

    @similar = @podcast.similar_podcasts
    @sponsors_90_days = SponsorMention.where(podcast_id: @podcast.id, published_at: 90.days.ago..).distinct.count(:brand_id)
  end

  # GET /podcasts/:slug/sign_in: sign in, then back to this podcast's Audience section (its teaser's link). Devise keeps
  # the place; the page itself never writes the session, so it stays cacheable.
  def sign_in_first
    podcast = find_podcast { |slug| podcast_sign_in_path(slug) } or return
    return redirect_to(podcast_path(podcast, anchor: "audience")) if user_signed_in?

    store_location_for(:user, podcast_path(podcast, anchor: "audience"))
    redirect_to new_user_session_path
  end

  # GET /podcasts/:slug/status?n=2: while the podcast's feed is being read, its page polls this; once it's read, the
  # answer reloads the page.
  def status
    noindex!
    @podcast = find_podcast { |slug| podcast_status_path(slug) } or return
    @poll = params[:n].to_i.clamp(1, MAX_POLLS)
  end

  private

  EpisodeRow = Data.define(:episode, :brands)
  SponsorBrand = Data.define(:name, :slug)

  # The podcast page's episodes, newest first, each with the brands found sponsoring it (one query each). Read by the
  # view inside its fragment cache, so a cached list costs nothing.
  def page_episodes
    @page_episodes ||= begin
      episodes = Episode.where(podcast_id: @podcast.id).newest_first.limit(EPISODE_LIMIT).strict_loading.to_a
      brands = SponsorMention.where(episode_id: episodes.map(&:id)).joins(:brand).order("brands.name")
                             .pluck(:episode_id, "brands.name", "brands.slug")
                             .group_by(&:first).transform_values { |rows| rows.map { |_, name, slug| SponsorBrand.new(name, slug) } }
      episodes.map { |episode| EpisodeRow.new(episode, brands.fetch(episode.id, [])) }
    end
  end

  # What the page shows beyond the podcast row: its listing and owner, its readings, and requests from brands
  # (Request a spot counts them), whose changes don't touch the podcast.
  def page_etag
    [ @podcast, @podcast.owner_show, @podcast.listing, @podcast.stat_readings.map(&:updated_at).max,
      Conversation.where(podcast_id: @podcast.id).maximum(:updated_at) ]
  end

  # Podcasts LazyAdd added for this search (or added earlier and still pending), not already in the results. Crawlers
  # never add shows. The outside directory failing never fails the page.
  def lazy_add
    return [] if MediaKit.bot?(request.user_agent)

    result = ::Catalog::LazyAdd.call(@directory.query)
    listed = @podcasts.map(&:id)
    (result.added + result.found.select(&:pending?)).uniq(&:id)
      .reject { |podcast| listed.include?(podcast.id) || podcast.removed? }.first(ADDING_LIMIT)
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { query: @directory.query })
    []
  end

  # { podcast_id => distinct brands found sponsoring it }, for the cards.
  def sponsor_counts(podcasts)
    return {} if podcasts.empty?

    SponsorMention.where(podcast_id: podcasts.map(&:id)).group(:podcast_id).distinct.count(:brand_id)
  end
end
