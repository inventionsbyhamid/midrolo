module Catalog
  # Reads a podcast's feed and stores what it learns. For now this is what RefreshShowFeedJob did for a show (the owner
  # email, website, cadence and episode count); lane L1 makes it the full ingest (episodes, people, artwork, sponsors,
  # status, next fetch). Feed problems come back as warnings from FeedReader and are ignored: the podcast keeps what it
  # has. One ingest per podcast at a time. Enqueue it through Podcast#ingest_later, which sets the priority.
  class IngestPodcastJob < ApplicationJob
    queue_as :catalog
    queue_with_priority Podcast::INGEST_PRIORITIES.fetch(:normal)
    limits_concurrency to: 1, key: ->(podcast_id) { podcast_id }, duration: 5.minutes

    def perform(podcast_id)
      podcast = Podcast.find_by(id: podcast_id)
      return if podcast.nil? || podcast.removed?

      feed = Podcasts::FeedReader.new.read(podcast.feed_url, max_episodes: 50)
      updates = { feed_checked_at: Time.current }
      updates[:owner_email] = feed.owner_email if feed.owner_email.present?
      website = Show.http_url(feed.website)
      updates[:website] = website if website
      updates[:cadence_days] = feed.cadence_days if feed.cadence_days.present?
      # The reader caps episodes, so only trust its count when it beats what we already know.
      updates[:episode_count] = feed.episodes.size if feed.episodes.size > podcast.episode_count.to_i
      podcast.update!(updates)
    end
  end
end
