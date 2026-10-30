module Catalog
  # Seeds the catalog with popular podcasts from Apple's public Top Podcasts chart (catalog:seed_charts), so the public
  # directory has shows people know, with long sponsor histories, beside the mid-size shows the Qloo seed brings. No
  # Qloo calls.
  #
  # Each charted show the catalog doesn't hold (by Apple id) goes the usual way in: ShowLookup with its Apple link (the
  # directory's record for that Apple id). When the directory refuses the id or doesn't know it, Apple's lookup API
  # gives the feed URL and ShowLookup takes that (the directory's record for the URL, else the feed itself). The podcast
  # is created by Catalog::NewPodcast with source "admin" and its ingest queued at the seed's low priority (20).
  # Directory and Apple lookups are paced to about one a second.
  #
  # Idempotent: a show already in the catalog (by Apple id, or found by directory id or feed URL, which stores its Apple
  # id for the next run) counts as existing. Removed podcasts and suppressed feeds are skipped, never brought back.
  #
  #   Catalog::SeedFromCharts.call(country: "us", limit: 200, genre: nil, log: ->(line) { puts line })
  class SeedFromCharts
    DEFAULT_COUNTRY = "us".freeze
    DEFAULT_LIMIT = AppleChart::MAX_LIMIT
    INTERVAL = 1.0 # seconds between directory or Apple lookups
    PROGRESS_EVERY = 25

    # charted: the chart's shows. added; existing: already in the catalog; skipped: removed or suppressed; failed: no
    # feed found or read.
    Result = Data.define(:charted, :added, :existing, :skipped, :failed)

    def self.call(country: DEFAULT_COUNTRY, limit: DEFAULT_LIMIT, genre: nil, log: nil, sleeper: ->(seconds) { sleep(seconds) },
                  clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      new(country:, limit:, genre:, log:, sleeper:, clock:).call
    end

    def initialize(country:, limit:, genre:, log:, sleeper:, clock:)
      @country = country
      @limit = limit
      @genre = genre.presence
      @log = log
      @sleeper = sleeper
      @clock = clock
      @counts = Hash.new(0)
      @last_lookup = nil
    end

    # Raises ArgumentError for a bad country, limit or genre, and AppleChart::Unavailable when the chart can't be read.
    def call
      entries = AppleChart.top(country: @country, limit: @limit, genre: @genre)
      known = Podcast.where(apple_id: entries.map { |entry| entry.apple_id.to_i }).pluck(:apple_id, :status).to_h
      entries.each.with_index(1) do |entry, index|
        @counts[outcome(entry, known[entry.apple_id.to_i])] += 1
        say("#{index}/#{entries.size} read: #{@counts[:added]} added so far") if (index % PROGRESS_EVERY).zero?
      end
      Result.new(charted: entries.size, added: @counts[:added], existing: @counts[:existing], skipped: @counts[:skipped],
                 failed: @counts[:failed])
    end

    private

    # A show the catalog holds by its Apple id (status given) is existing, or skipped when removed; any other is added.
    def outcome(entry, status)
      return add(entry) if status.nil?

      status == "removed" ? :skipped : :existing
    end

    # How a show the catalog lacks came out: :added, :existing (found by directory id or feed URL), :skipped or :failed.
    def add(entry)
      attributes, why = lookup(entry)
      return failed(entry, why) unless attributes
      return skipped(entry, "its feed is suppressed") if Suppression.podcast?(feed_url: attributes[:feed_url])

      podcast, created = NewPodcast.find_or_create(attributes, source: "admin", priority: :low)
      return failed(entry, "the catalog didn't take it") unless podcast
      return skipped(entry, "it was removed from the catalog") if podcast.removed?

      created ? :added : :existing
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { apple_id: entry.apple_id })
      failed(entry, "#{e.class}: #{e.message}")
    end

    # [attributes, nil] for the show's feed, or [nil, why not].
    def lookup(entry)
      pace
      attributes = attributes_for(ShowLookup.call(feed_url: "https://podcasts.apple.com/podcast/id#{entry.apple_id}"), entry)
      attributes ? [ attributes, nil ] : from_apple(entry)
    rescue Podcasts::Directory::Unavailable
      from_apple(entry)
    end

    # The feed URL from Apple's lookup, then ShowLookup for that URL (the directory's record, else the feed itself).
    def from_apple(entry)
      pace
      feed_url = AppleChart.feed_url(entry.apple_id)
      return [ nil, "Apple lists no feed for it" ] unless feed_url

      pace
      attributes = attributes_for(ShowLookup.call(feed_url: feed_url), entry)
      attributes ? [ attributes, nil ] : [ nil, "its feed can't be read (#{feed_url})" ]
    rescue AppleChart::Unavailable => e
      [ nil, e.message ]
    end

    # A lookup's attributes with the chart's Apple id (and name, when the lookup has no title), or nil when it found
    # no feed URL of its own: a directory record without one comes back with the Apple link in its place.
    def attributes_for(result, entry)
      return unless result.ok?

      attributes = result.attributes
      return if attributes[:feed_url].blank? || attributes[:feed_url].match?(ShowLookup::APPLE_URL)

      attributes.merge(itunes_id: entry.apple_id, title: attributes[:title].presence || entry.name)
    end

    # At most one directory or Apple lookup a second.
    def pace
      if @last_lookup
        wait = INTERVAL - (@clock.call - @last_lookup)
        @sleeper.call(wait) if wait.positive?
      end
      @last_lookup = @clock.call
    end

    def failed(entry, why)
      say("failed: #{entry.name} (Apple id #{entry.apple_id}): #{why}")
      :failed
    end

    def skipped(entry, why)
      say("skipped: #{entry.name} (Apple id #{entry.apple_id}): #{why}")
      :skipped
    end

    def say(line) = @log&.call(line)
  end
end
