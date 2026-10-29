module Catalog
  # A podcast's feed moved for good (Catalog::Ingest: a chain of permanent redirects, or itunes:new-feed-url). The move
  # is recorded (PodcastFeedMove), and on a claimed podcast the claim is released: its owner proved control of the old
  # feed, not the new one, so a claimed decoy can't carry its claim onto a real show's feed (code review H1). The owner
  # show becomes a draft workspace again (its kit and reports stay with it), the podcast is unclaimed, the numbers the
  # owner brought (verified platform readings, the provided figure) go, and the owner is asked to verify the new feed.
  #
  #   released = Catalog::FeedMove.record(podcast, from:, to:, via:)  # in the ingest's transaction, before the save
  #   Catalog::FeedMove.released(podcast, released, from:, to:)       # after the save: listing columns and the email
  module FeedMove
    # The readings a claim brought with it: numbers read through the owner's platform connections, or typed by them.
    OWNER_TRUSTS = %w[verified provided].freeze

    module_function

    # Records the move and releases the claim. Returns the released owner show, or nil when nobody had claimed it.
    def record(podcast, from:, to:, via:)
      owner = Show.where(podcast_id: podcast.id).where.not(verified_at: nil).lock.first
      if owner
        owner.update_columns(verified_at: nil, updated_at: Time.current)
        podcast.claimed_at = nil
        StatReading.where(podcast_id: podcast.id, trust: OWNER_TRUSTS).delete_all
      end
      PodcastFeedMove.create!(podcast: podcast, from_url: from, to_url: to, via: via, released_show: owner)
      Rails.logger.info("[Catalog::FeedMove] podcast #{podcast.id} moved #{via}#{" (claim of show #{owner.id} released)" if owner}")
      owner
    end

    # Once the podcast is saved with its new feed: its directory columns follow (no owner, no listing, no numbers), and
    # the released owner is asked to verify the new feed.
    def released(podcast, owner, from:, to:)
      return unless owner

      podcast.refresh_listing!
      ClaimMailer.with(show: owner, from: from, to: to).feed_moved.deliver_later
    end
  end
end
