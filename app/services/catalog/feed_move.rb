module Catalog
  # A podcast's feed moved for good (Catalog::Ingest: a chain of permanent redirects, or itunes:new-feed-url). The move
  # is recorded (PodcastFeedMove), and on a claimed podcast the claim is released: its owner proved control of the old
  # feed, not the new one, so a claimed decoy can't carry its claim onto a real show's feed (code review H1). The owner
  # show becomes a draft workspace again (its kit and reports stay with it), the podcast is unclaimed, the numbers the
  # owner brought (verified platform readings, the provided figure) go, and the owner is asked to verify the new feed.
  #
  # The claim stays when the new feed shows the same owner (final review N2): it names an address the owner proved (their
  # own Google sign in, or an address an emailed code of theirs went to), or it carries the podcast:guid the old URL
  # minted for itself. Neither can be faked from a decoy: the stored owner address and guid alone are only what the old
  # feed said, so they prove nothing. Ingest never calls this for a change of scheme, www., case or trailing slash.
  #
  # Every pending code and token for the podcast is retired (N1), under the podcast's row lock, the lock a verification
  # holds while it claims: a claim either finishes first and is seen here, or sees this move and is refused.
  #
  #   released = Catalog::FeedMove.record(podcast, from:, to:, via:, feed:, guid_was:)  # in the ingest's transaction
  #   Catalog::FeedMove.drop_old_episodes(podcast, keep: guids) if released             # same transaction (N4)
  #   Catalog::FeedMove.released(podcast, released, from:, to:)  # after the save: listing columns and the email
  module FeedMove
    # The readings a claim brought with it: numbers read through the owner's platform connections, or typed by them.
    OWNER_TRUSTS = %w[verified provided].freeze

    module_function

    # Records the move and releases the claim unless the new feed (as parsed at its new URL) shows the same owner.
    # guid_was is the podcast:guid stored before this read. Returns the released owner show, or nil when the claim
    # stays or nobody had claimed it.
    def record(podcast, from:, to:, via:, feed: nil, guid_was: nil)
      Podcast.lock.find(podcast.id) # before anything else; podcast itself holds this read's unsaved columns
      owner = Show.where(podcast_id: podcast.id).where.not(verified_at: nil).lock.first
      owner = nil if owner && same_owner?(owner, feed, from: from, guid_was: guid_was)
      if owner
        owner.update_columns(verified_at: nil, updated_at: Time.current)
        podcast.claimed_at = nil
        StatReading.where(podcast_id: podcast.id, trust: OWNER_TRUSTS).delete_all
      end
      ShowVerification.where(show_id: Show.where(podcast_id: podcast.id).select(:id)).unexpired
                      .update_all(expires_at: Time.current, updated_at: Time.current)
      PodcastFeedMove.create!(podcast: podcast, from_url: from, to_url: to, via: via, released_show: owner)
      Rails.logger.info("[Catalog::FeedMove] podcast #{podcast.id} moved #{via}#{" (claim of show #{owner.id} released)" if owner}")
      owner
    end

    # The new feed names an address the owner proved, or carries the guid the old URL minted (see above).
    def same_owner?(owner, feed, from:, guid_was:)
      return false if feed.nil?

      address = ShowVerification.normalize_address(feed.owner_email)
      proven = address.present? &&
               (owner.owner_email_matches_user?(address) ||
                owner.verifications.email.where.not(verified_at: nil).exists?(sent_to: address))
      minted = guid_was.present? && feed.podcast_guid.to_s.downcase == guid_was.downcase &&
               guid_was.downcase == Podcast.podcast_guid_for(from)
      proven || minted
    end

    # After a move that released a claim (N4): the old feed's episodes the new feed doesn't carry, and their sponsor
    # reads, go, so a decoy's planted episodes and "brought to you by" lines never show on the real show. The brands
    # they credited are recounted.
    def drop_old_episodes(podcast, keep:)
      gone = Episode.where(podcast_id: podcast.id).where.not(guid: keep)
      mentions = SponsorMention.where(episode_id: gone.select(:id))
      brand_ids = mentions.distinct.pluck(:brand_id)
      mentions.delete_all
      gone.delete_all
      return if brand_ids.empty?

      Brand.where(id: brand_ids).update_all(<<~SQL.squish)
        sponsor_mentions_count = (SELECT COUNT(*) FROM sponsor_mentions WHERE sponsor_mentions.brand_id = brands.id),
        updated_at = CURRENT_TIMESTAMP
      SQL
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
