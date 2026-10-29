module Catalog
  # How the catalog takes in a show it doesn't have yet, from a directory hit (Podcasts::ShowInfo) or a ShowLookup
  # result: one podcast per show (found by directory id, Apple id or normalized feed URL, so a second URL for a known
  # show finds it), created pending with only the ids, the feed URL, and the title and author to show until its feed
  # is read. Everything else comes from the show's own feed (vendor terms, build spec section 2). A new podcast's
  # ingest is queued at once, and next_fetch_at is set as a safety net in case that job is lost.
  module NewPodcast
    COLUMNS = %i[directory_id itunes_id feed_url title author language].freeze
    # The refresh loop reads a new podcast's feed this long after it was added, if its first ingest hasn't run.
    SAFETY_NET = 30.minutes

    module_function

    # [podcast, created] for a directory hit or lookup attributes, or nil for one the catalog can't take (no feed URL,
    # no title, suppressed).
    def find_or_create(info, source:, priority:)
      attrs = info.to_h.symbolize_keys.slice(*COLUMNS)
      return nil if attrs[:feed_url].blank? || attrs[:title].blank? || Suppression.podcast?(feed_url: attrs[:feed_url])

      podcast = Podcast.find_or_create_from_lookup!(attrs.merge(source: source))
      created = podcast.previously_new_record?
      if created
        podcast.update_columns(next_fetch_at: SAFETY_NET.from_now)
        podcast.ingest_later(priority: priority)
      end
      [ podcast, created ]
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.info("[Catalog::NewPodcast] skipped #{attrs[:feed_url]}: #{e.message}")
      nil
    end

    # Whether a directory hit is in English, or doesn't say.
    def english?(info)
      language = info.language.to_s.strip.downcase
      language.empty? || language == "en" || language.start_with?("en-", "en_")
    end
  end
end
