module Stats
  # The ownership check (build spec section 11): a connection's numbers count only when its podcast is claimed by the
  # user who made the connection, and the show the platform answers for is this podcast (its normalized title is the
  # podcast's, or its RSS URL is the podcast's feed). Midrolo's service account sees every show that invited it, so
  # this is what keeps one show's numbers off another's page. Each check returns nil when it passes, else the plain
  # words the stats screen shows.
  module Ownership
    module_function

    # Before anything is fetched: only the claimed owner's connection reads anything.
    def owner_problem(connection)
      podcast = connection.podcast
      return "Claim this show first. Verified numbers count only for the show's owner." unless podcast.claimed?

      owner_id = podcast.owner_show&.user_id
      return nil if owner_id.present? && owner_id == connection.user_id

      "Another account owns this show on Midrolo, so only that account can connect its stats."
    end

    # A connection whose platform show matched by name only, while another catalog podcast has that name: a clone could
    # be pointing at a real show's id, so nothing counts until an admin approves it (/admin/stat_connections).
    NEEDS_REVIEW = "Another show has the same name; Midrolo will check it by hand.".freeze

    # After a fetch: show is the result's "show" ({ "id", "name", "rss_url" }). The feed is proof; the name alone is
    # proof only while no other catalog podcast shares it, for a connection that never counted before and that no admin
    # approved (a show verified before a clone appeared stays verified; one platform show backs one connection).
    def show_problem(connection, show)
      podcast = connection.podcast
      return nil if same_feed?(show["rss_url"], podcast.feed_url)

      name = show["name"].to_s.squish
      if name.present? && Podcast.title_key_for(name).present? && Podcast.title_key_for(name) == podcast.title_key
        return name_twin?(connection) ? NEEDS_REVIEW : nil
      end

      # Never the platform show's own name: it would tell this user about a show that isn't theirs.
      platform = ::Stats.platform_name(connection.provider)
      if name.present?
        "The #{platform} show at that link isn't #{podcast.title.truncate(80)}. Check the link you pasted."
      else
        "We couldn't confirm that the #{platform} show is #{podcast.title.truncate(80)}. Check the link you pasted."
      end
    end

    def needs_review?(connection) = connection.mismatch? && connection.last_error == NEEDS_REVIEW

    def name_twin?(connection)
      return false if connection.approved_at.present? || connection.activated_at.present?

      podcast = connection.podcast
      Podcast.where(title_key: podcast.title_key).where.not(id: podcast.id).where.not(status: "removed").exists?
    end

    # Feed URLs match without their scheme (http and https are the same feed) once normalized like the catalog's.
    def same_feed?(rss_url, feed_url)
      a = Podcast.normalize_feed_url(rss_url.to_s)&.sub(%r{\Ahttps?://}i, "")
      b = Podcast.normalize_feed_url(feed_url.to_s)&.sub(%r{\Ahttps?://}i, "")
      a.present? && a == b
    end
  end
end
