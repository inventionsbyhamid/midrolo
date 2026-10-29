module Catalog
  # A search that grows the catalog. Searches the catalog first (full text and trigram, Podcast.search_catalog); with
  # fewer than 5 hits, asks Podcasts::Directory.current (it caches its answers) and creates up to MAX_ADDED missing
  # podcasts as pending (source "search"), their ingest queued at normal priority, never a claim's (code review M5).
  # A feed URL or an Apple Podcasts link is looked up directly (ShowLookup): from the directory for anyone, and by
  # reading a feed the directory doesn't list only for a signed-in user (code review M4). The directory being down
  # never fails the search: it answers with what the catalog has. The caller throttles.
  #
  #   result = Catalog::LazyAdd.call("darknet diaries")
  #   result.found # podcasts already in the catalog, best match first
  #   result.added # podcasts this call created (pending until their ingest finishes)
  class LazyAdd
    Result = Data.define(:found, :added) do
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

    # signed_in: whether a signed-in user searched (only they may add a feed by its URL alone).
    def self.call(query, signed_in: false) = new(query, signed_in).call

    def self.url?(query) = query.to_s.strip.match?(URL)

    def initialize(query, signed_in = false)
      @query = query.to_s.squish.first(Podcast::Catalog::QUERY_LIMIT)
      @signed_in = signed_in
    end

    def call
      return Result.new(found: [], added: []) if @query.empty?
      return from_url if @query.match?(URL)

      found = Podcast.search_catalog(@query).limit(LOCAL_LIMIT).to_a
      return Result.new(found: found, added: []) if found.size >= MIN_FOUND

      added = []
      directory_hits.each do |info|
        break if added.size >= MAX_ADDED

        podcast, created = NewPodcast.find_or_create(info, source: "search", priority: PRIORITY)
        next if podcast.nil? || podcast.removed?

        created ? added << podcast : found << podcast
      end
      Result.new(found: found.uniq, added: added)
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

      lookup = ShowLookup.call(feed_url: @query, read_feed: @signed_in)
      return Result.new(found: [], added: []) unless lookup.ok?

      podcast, created = NewPodcast.find_or_create(lookup.attributes, source: "search", priority: PRIORITY)
      return Result.new(found: [], added: []) if podcast.nil? || podcast.removed?

      created ? Result.new(found: [], added: [ podcast ]) : Result.new(found: [ podcast ], added: [])
    rescue Podcasts::Directory::Unavailable
      Result.new(found: [], added: [])
    end
  end
end
