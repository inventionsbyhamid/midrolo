# Podcast: feed ingest, artwork, refresh scheduling and the catalog's own queries.
# Lane L1 adds its methods here, and only here (build spec section 10), so lanes don't edit the same model file.
module Podcast::Catalog
  extend ActiveSupport::Concern

  # A show with an episode in this window is active; one with older episodes only is dormant.
  ACTIVE_WINDOW = 90.days
  # The fewest episodes a page needs before search engines may index it (plan section 3, rule 6).
  MIN_INDEXABLE_EPISODES = 3
  # How often a feed is read (build spec L1): claimed shows hourly, then by how recent the last episode is.
  CLAIMED_FETCH_INTERVAL = 1.hour
  FETCH_INTERVALS = [ [ 7.days, 6.hours ], [ 30.days, 12.hours ], [ 90.days, 24.hours ] ].freeze
  DORMANT_FETCH_INTERVAL = 7.days
  # Each failure in a row doubles the wait, up to this.
  MAX_FETCH_INTERVAL = 7.days
  # A show that was read before is failed after this many failures in a row; a new one after its first.
  FAILED_AFTER = 3
  # The longest search query the catalog reads.
  QUERY_LIMIT = 200

  class_methods do
    # Podcasts matching a search, best first: full text over title, author and description (the stored searchable
    # vector) or a title that reads like the query (trigram). Removed podcasts never match. Both conditions use their
    # GIN index.
    def search_catalog(query)
      query = query.to_s.squish.first(QUERY_LIMIT)
      return none if query.empty?

      tsquery = "(websearch_to_tsquery('simple', :query) || websearch_to_tsquery('english', :query))"
      rank = sanitize_sql_array([ "ts_rank(podcasts.searchable, #{tsquery}) + similarity(podcasts.title, :query) DESC",
                                  { query: query } ])
      where.not(status: "removed")
           .where("podcasts.searchable @@ #{tsquery} OR podcasts.title % :query", query: query)
           .order(Arel.sql(rank), :id)
    end
  end

  # The status a readable feed gives: active with an episode in the last 90 days, else dormant.
  def feed_status(now = Time.current)
    last_published_at && last_published_at >= now - ACTIVE_WINDOW ? "active" : "dormant"
  end

  # Its page says the feed couldn't be read lately: failed, or claimed (which stays listed) after FAILED_AFTER failed
  # reads in a row.
  def feed_unreachable? = failed? || (claimed? && fetch_failures.to_i >= FAILED_AFTER)

  # Plan section 3, rule 6: only pages with real content get indexed. Active or dormant, 3 or more episodes, stored
  # artwork that isn't taken down, and a description. And a show someone vouches for: one a directory lists (Podcast
  # Index or Apple), a claimed one, or one an admin added. A feed added by its URL alone stays noindex until it is
  # claimed, so nobody can fill midrolo.com's search results with feeds of their own (code review M4).
  def meets_index_rule?
    (active? || dormant?) && episode_count.to_i >= MIN_INDEXABLE_EPISODES && description.present? && artwork_stored? &&
      vouched_for?
  end

  # Listed by a directory (the demo directory's feeds count in development), claimed, or added by an admin or a sample.
  def vouched_for?
    directory_id.present? || apple_id.present? || claimed? || source_admin? || source_sample?
  end

  def artwork_stored?
    image = artwork_image
    image.present? && image.visible? && image.file.attached?
  end

  # How long until the feed is read again: by claim and recency (build spec L1), doubled for each failure in a row,
  # at most 7 days.
  def next_fetch_interval(now = Time.current)
    base = if claimed? then CLAIMED_FETCH_INTERVAL
    elsif last_published_at.nil? then DORMANT_FETCH_INTERVAL
    else
      FETCH_INTERVALS.find { |window, _| last_published_at >= now - window }&.last || DORMANT_FETCH_INTERVAL
    end
    return base if fetch_failures.to_i.zero?

    [ base * (2**[ fetch_failures, 10 ].min), MAX_FETCH_INTERVAL ].min
  end
end
