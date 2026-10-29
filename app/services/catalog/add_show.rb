module Catalog
  # One show added by hand (rake catalog:add): an RSS feed URL, an Apple Podcasts link, or a name searched in the
  # directory. A name takes the hit whose title matches it (Podcast.title_key_for), else the directory's first; the
  # other hits come back so the operator can pick another by its feed URL. Spotify links can't be read (Spotify data
  # can't be stored), so they ask for the show's RSS feed instead. The podcast's source is "admin"; its ingest is
  # queued at high priority (the rake task also runs it at once).
  class AddShow
    Result = Data.define(:podcast, :created, :others, :error) do
      def ok? = error.nil?
    end

    SPOTIFY = %r{\Ahttps?://(?:open|podcasters|creators)\.spotify\.com/}i
    URL = %r{\Ahttps?://}i
    BLANK = "Give an RSS feed URL, an Apple Podcasts link or a show name.".freeze
    SPOTIFY_ERROR = "Spotify links can't be read. Give the show's RSS feed URL or its name.".freeze
    NOT_FOUND = "The directory has no show by that name. Give its RSS feed URL.".freeze
    UNAVAILABLE = "The podcast directory is not answering. Try again, or give the RSS feed URL.".freeze
    NOT_ADDED = "That show can't be added (no feed URL, or it was removed from the catalog).".freeze

    def self.call(query) = new(query).call

    def initialize(query)
      @query = query.to_s.strip
    end

    def call
      return failure(BLANK) if @query.empty?
      return failure(SPOTIFY_ERROR) if @query.match?(SPOTIFY)

      @query.match?(URL) ? from_url : from_name
    rescue Podcasts::Directory::Unavailable
      failure(UNAVAILABLE)
    end

    private

    def from_url
      lookup = ShowLookup.call(feed_url: @query)
      lookup.ok? ? add(lookup.attributes, []) : failure(lookup.error)
    end

    def from_name
      hits = Podcasts::Directory.current.search(@query, limit: 5).select { |hit| hit.feed_url.present? }
      return failure(NOT_FOUND) if hits.empty?

      key = Podcast.title_key_for(@query)
      pick = hits.find { |hit| Podcast.title_key_for(hit.title) == key } || hits.first
      add(pick, hits - [ pick ])
    end

    def add(info, others)
      podcast, created = NewPodcast.find_or_create(info, source: "admin", priority: :high)
      return failure(NOT_ADDED) if podcast.nil?

      Result.new(podcast: podcast, created: created, others: others, error: nil)
    end

    def failure(message) = Result.new(podcast: nil, created: false, others: [], error: message)
  end
end
