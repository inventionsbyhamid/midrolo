module Catalog
  # A search that grows the catalog. Searches the catalog first (full text and trigram, Podcast.search_catalog); with
  # fewer than 5 hits, asks Podcasts::Directory.current (it caches its answers) and creates up to MAX_ADDED missing
  # podcasts as pending (source "search"), their ingest queued at normal priority, never a claim's (code review M5).
  # A feed URL or an Apple Podcasts link is looked up directly (ShowLookup): from the directory for anyone, and by
  # reading a feed the directory doesn't list only for a signed-in user (code review M4). The directory being down
  # never fails the search: it answers with what the catalog has. The caller throttles.
  #
  # Searches add at most daily_cap podcasts a day (AppSettings catalog_search_adds_per_day, counted in Rails.cache by
  # UTC day): past it, a search answers from the catalog alone and never asks the directory (final review N16).
  #
  #   result = Catalog::LazyAdd.call("darknet diaries")
  #   result.found  # podcasts already in the catalog, best match first
  #   result.added  # podcasts this call created (pending until their ingest finishes)
  #   result.capped # true when the day's cap kept this search from adding
  class LazyAdd
    Result = Data.define(:found, :added, :capped) do
      def initialize(found:, added:, capped: false) = super

      def podcasts = found + added
    end

    # Fewer local hits than this asks the directory.
    MIN_FOUND = 5
    # The most podcasts one search adds, so a burst of random searches can't flood the catalog queue.
    MAX_ADDED = 2
    PRIORITY = :normal
    LOCAL_LIMIT = 20
    DIRECTORY_LIMIT = 10
    URL = %r{\Ahttps?://}i
    DAILY_CAP = 300
    ADDED_KEY = "catalog:search_adds".freeze

    # signed_in: whether a signed-in user searched (only they may add a feed by its URL alone).
    def self.call(query, signed_in: false) = new(query, signed_in).call

    def self.url?(query) = query.to_s.strip.match?(URL)

    def self.daily_cap = AppSettings.get(:catalog_search_adds_per_day, default: DAILY_CAP).to_i

    def self.added_today = Rails.cache.read(added_key).to_i

    def self.capped? = added_today >= daily_cap

    def self.count_added! = Rails.cache.increment(added_key, 1, expires_in: 2.days)

    def self.added_key = "#{ADDED_KEY}:#{Time.current.utc.to_date.iso8601}"

    def initialize(query, signed_in = false)
      @query = query.to_s.squish.first(Podcast::Catalog::QUERY_LIMIT)
      @signed_in = signed_in
    end

    def call
      return Result.new(found: [], added: []) if @query.empty?
      return from_url if @query.match?(URL)

      found = Podcast.search_catalog(@query).limit(LOCAL_LIMIT).to_a
      return Result.new(found: found, added: []) if found.size >= MIN_FOUND
      return Result.new(found: found, added: [], capped: true) if self.class.capped?

      added = []
      capped = false
      directory_hits.each do |info|
        break if added.size >= MAX_ADDED
        break capped = true if self.class.capped?

        podcast, created = NewPodcast.find_or_create(info, source: "search", priority: PRIORITY)
        next if podcast.nil? || podcast.removed?

        self.class.count_added! if created
        created ? added << podcast : found << podcast
      end
      Result.new(found: found.uniq, added: added, capped: capped)
    end

    private

    def directory_hits
      Podcasts::Directory.current.search(@query, limit: DIRECTORY_LIMIT)
    rescue Podcasts::Directory::Unavailable => e
      Rails.logger.warn("[Catalog::LazyAdd] directory unavailable: #{e.message}")
      []
    end

    def from_url
      known = Podcast.where.not(status: "removed").find_by(feed_url: Podcast.normalize_feed_url(@query))
      return Result.new(found: [ known ], added: []) if known
      return Result.new(found: [], added: [], capped: true) if self.class.capped?

      lookup = ShowLookup.call(feed_url: @query, read_feed: @signed_in)
      return Result.new(found: [], added: []) unless lookup.ok?

      podcast, created = NewPodcast.find_or_create(lookup.attributes, source: "search", priority: PRIORITY)
      return Result.new(found: [], added: []) if podcast.nil? || podcast.removed?

      self.class.count_added! if created

      created ? Result.new(found: [], added: [ podcast ]) : Result.new(found: [ podcast ], added: [])
    rescue Podcasts::Directory::Unavailable
      Result.new(found: [], added: [])
    end
  end
end
