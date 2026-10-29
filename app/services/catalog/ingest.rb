module Catalog
  # One feed read for one podcast (Catalog::IngestPodcastJob runs it): fetch (conditional, capped), skip the parse when
  # the bytes haven't changed, parse, upsert the newest episodes and the people the feed names, update the podcast's
  # feed columns, status, indexable flag and next fetch, then queue the artwork and the sponsor scan of new episodes.
  #
  # A bad feed never raises and never wedges anything: a failure is counted, kept in last_error and backed off (the
  # wait doubles, up to 7 days). podcast:block, itunes:block and suppressions remove the podcast. Ingest writes only
  # feed columns (spec ruling 11): the listing and stats columns belong to Podcast#refresh_listing!. Episodes are never
  # deleted (ruling 4); a person the feed stops naming is.
  class Ingest
    # The episode columns a later read of the same guid updates. The slug is set on insert only (ruling 5), so a
    # page's URL never moves.
    EPISODE_UPDATES = %i[title description published_at duration_seconds episode_type season number enclosure_url link
                         transcript_url].freeze
    PERSON_UPDATES = %i[name href img_url episodes_count].freeze

    Outcome = Data.define(:status, :new_episode_ids, :error)

    def self.call(podcast, priority: Podcast::INGEST_PRIORITIES.fetch(:normal)) = new(podcast, priority).call

    def initialize(podcast, priority)
      @podcast = podcast
      @priority = priority
    end

    def call
      return outcome(:skipped) if @podcast.removed?

      @now = Time.current
      return remove!("suppressed") if suppressed?(@podcast.podcast_guid)

      fetched = FeedFetcher.call(@podcast.feed_url, etag: @podcast.feed_etag, last_modified: @podcast.feed_last_modified)
      return fail!(fetched.error) if fetched.error?
      return unchanged!(fetched) if fetched.not_modified? || (fetched.sha256 == @podcast.feed_sha256 && !@podcast.pending?)

      feed = FeedParser.call(fetched.body, feed_url: @podcast.feed_url, now: @now)
      return remove!("feed_blocked_by_show") if feed.blocked
      return remove!("suppressed") if suppressed?(feed.podcast_guid)

      store!(feed, fetched)
    rescue FeedParser::Unreadable => e
      fail!(e.message)
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { podcast_id: @podcast.id })
      @podcast.reload
      fail!("ingest_error")
    end

    private

    def store!(feed, fetched)
      new_ids = []
      artwork_was = @podcast.artwork_url
      feed_was = @podcast.feed_url
      released = nil
      Podcast.transaction do
        new_ids = upsert_episodes(feed.episodes)
        upsert_people(feed)
        @podcast.assign_attributes(feed_columns(feed, fetched))
        if @podcast.feed_url != feed_was
          released = FeedMove.record(@podcast, from: feed_was, to: @podcast.feed_url, via: move_via(fetched))
        end
        @podcast.status = @podcast.feed_status(@now)
        schedule
        @podcast.save!
      end
      FeedMove.released(@podcast, released, from: feed_was, to: @podcast.feed_url) if released
      queue_artwork if artwork_was != @podcast.artwork_url || !@podcast.artwork_stored?
      ::Sponsors::ScanJob.perform_later(@podcast.id, new_ids) if new_ids.any?
      outcome(:updated, new_ids)
    end

    # The feed's own columns. A feed with no title keeps the one the podcast has (the column can't be empty).
    def feed_columns(feed, fetched)
      columns = {
        title: feed.title.presence || @podcast.title, author: feed.author, description: feed.description,
        language: feed.language, explicit: feed.explicit, itunes_type: feed.itunes_type, categories: feed.categories,
        website: feed.website, artwork_url: feed.artwork_url, owner_email: feed.owner_email,
        hosting_provider: feed.hosting_provider, measurement: feed.measurement, cadence_days: feed.cadence_days,
        episode_count: feed.episode_count, first_published_at: feed.first_published_at,
        last_published_at: feed.last_published_at, feed_etag: fetched.etag, feed_last_modified: fetched.last_modified,
        feed_sha256: fetched.sha256
      }
      if fetched.truncated
        # Only the top of a huge feed was read: the older episodes it holds are still out there.
        columns[:episode_count] = [ feed.episode_count, @podcast.episode_count.to_i ].max
        columns[:first_published_at] = [ feed.first_published_at, @podcast.first_published_at ].compact.min
      end
      columns[:podcast_guid] = feed.podcast_guid if guid_free?(feed.podcast_guid)
      columns[:feed_url] = moved_to(feed, fetched) || @podcast.feed_url
      columns
    end

    # The feed's podcast:guid, unless another podcast already holds it (the same show under another feed URL: the
    # first one keeps it, unique index).
    def guid_free?(guid)
      guid.present? && guid != @podcast.podcast_guid && !Podcast.where(podcast_guid: guid).where.not(id: @podcast.id).exists?
    end

    # The feed's new home, when it moved for good (permanent redirects, or itunes:new-feed-url) and no other podcast
    # has that URL. A move releases a claim (Catalog::FeedMove).
    def moved_to(feed, fetched)
      url = Podcast.normalize_feed_url(fetched.moved_to || feed.new_feed_url)
      return nil if url.nil? || url == @podcast.feed_url || Podcasts::SafeUrl.blocked?(url)

      url unless Podcast.where(feed_url: url).where.not(id: @podcast.id).exists? || Suppression.podcast?(feed_url: url)
    end

    def move_via(fetched) = fetched.moved_to.present? ? "redirect" : "new_feed_url"

    # Upserts the parsed episodes by (podcast, guid) and returns the ids of those that are new.
    def upsert_episodes(episodes)
      return [] if episodes.empty?

      known = @podcast.episodes.where(guid: episodes.map(&:guid)).pluck(:guid, :slug).to_h
      slugs = new_slugs(episodes.reject { |episode| known.key?(episode.guid) })
      rows = episodes.map do |episode|
        episode.to_h.except(:people).merge(podcast_id: @podcast.id, slug: known[episode.guid] || slugs.fetch(episode.guid))
      end
      result = Episode.upsert_all(rows, unique_by: %i[podcast_id guid], update_only: EPISODE_UPDATES, returning: %i[id guid])
      result.rows.reject { |_id, guid| known.key?(guid) }.map(&:first)
    end

    # guid => slug for new episodes: Episode.slug_for against every slug the podcast already uses, each one given out
    # added before the next (the bare title when free, else the guid suffix). Existing episodes keep theirs.
    def new_slugs(episodes)
      return {} if episodes.empty?

      taken = @podcast.episodes.pluck(:slug).to_set
      episodes.to_h do |episode|
        slug = Episode.slug_for(episode.title, episode.guid, taken: taken)
        taken << slug
        [ episode.guid, slug ]
      end
    end

    # The people the feed names (podcast:person on the channel and its episodes), one row per name and role, with how
    # many of the read episodes name them. Anyone the feed no longer names is removed: only people the feed names show.
    def upsert_people(feed)
      people = (feed.people + feed.episodes.flat_map(&:people)).filter_map do |person|
        key = PodcastPerson.name_key_for(person.name)
        [ [ key, person.role ], person ] if key.present?
      end
      counts = feed.episodes.flat_map { |episode| episode.people.map { |p| [ PodcastPerson.name_key_for(p.name), p.role ] }.uniq }.tally
      rows = people.group_by(&:first).map do |(key, role), entries|
        found = entries.map(&:last)
        { podcast_id: @podcast.id, name: found.first.name, name_key: key, role: role, href: found.filter_map(&:href).first,
          img_url: found.filter_map(&:img_url).first, episodes_count: counts.fetch([ key, role ], 0) }
      end
      return @podcast.people.delete_all if rows.empty?

      result = PodcastPerson.upsert_all(rows, unique_by: %i[podcast_id name_key role], update_only: PERSON_UPDATES,
                                              returning: %i[id])
      @podcast.people.where.not(id: result.rows.map(&:first)).delete_all
    end

    # Nothing new (304, or the same bytes): the check is recorded, and the status and indexable flag move with time.
    # The page's caches change only when those do.
    def unchanged!(fetched)
      @podcast.assign_attributes(feed_etag: fetched.etag || @podcast.feed_etag,
                                 feed_last_modified: fetched.last_modified || @podcast.feed_last_modified)
      @podcast.status = @podcast.feed_status(@now) unless @podcast.pending?
      schedule
      save_quietly
      queue_artwork unless @podcast.artwork_stored?
      outcome(:unchanged)
    end

    def fail!(code)
      @podcast.fetch_failures = @podcast.fetch_failures.to_i + 1
      @podcast.last_error = code.to_s.first(250)
      @podcast.status = failure_status
      schedule(failed: true)
      unreachable_now = @podcast.claimed? && @podcast.fetch_failures == Podcast::Catalog::FAILED_AFTER
      # The page's note appears with the third failure, so its caches change then too.
      @podcast.save!(touch: unreachable_now || @podcast.status_changed? || @podcast.indexable_changed?)
      ClaimMailer.with(podcast: @podcast).feed_unreachable.deliver_later if unreachable_now
      outcome(:failed, [], code)
    end

    # A podcast never read fails at once, any other after FAILED_AFTER failures in a row. A claimed one that was read
    # before keeps its last good status instead (active or dormant as time goes on), so it stays in the directory, on
    # brand pages and in fit searches; its page says the feed couldn't be read lately and its owner is mailed once.
    def failure_status
      return "failed" if @podcast.pending?
      return @podcast.feed_status(@now) if @podcast.claimed? && (@podcast.last_published_at || @podcast.episode_count.to_i.positive?)

      @podcast.fetch_failures >= Podcast::Catalog::FAILED_AFTER ? "failed" : @podcast.status
    end

    # Taken out of the catalog: never fetched again, never indexed.
    def remove!(reason)
      @podcast.update!(status: "removed", indexable: false, next_fetch_at: nil, leased_until: nil, last_error: reason,
                       feed_checked_at: @now)
      outcome(:removed, [], reason)
    end

    # The bookkeeping every read ends with: checked now, the failure count and error, the lease freed, the indexable
    # flag, and the next fetch.
    def schedule(failed: false)
      unless failed
        @podcast.fetch_failures = 0
        @podcast.last_error = nil
      end
      @podcast.feed_checked_at = @now
      @podcast.leased_until = nil
      @podcast.indexable = @podcast.meets_index_rule?
      @podcast.next_fetch_at = @now + jitter(@podcast.next_fetch_interval(@now))
    end

    # Saves without touching updated_at unless what a page shows (status, indexable) changed.
    def save_quietly
      @podcast.save!(touch: @podcast.status_changed? || @podcast.indexable_changed?)
    end

    # Up to 5% more, so feeds checked together drift apart.
    def jitter(interval) = interval + (interval * 0.05 * rand)

    def queue_artwork
      return if Show.http_url(@podcast.artwork_url).nil?

      ArtworkJob.set(priority: @priority).perform_later(@podcast.id)
    end

    def suppressed?(guid) = Suppression.podcast?(guid: guid, feed_url: @podcast.feed_url)

    def outcome(status, new_ids = [], error = nil) = Outcome.new(status: status, new_episode_ids: new_ids, error: error)
  end
end
