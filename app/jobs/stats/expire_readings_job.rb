module Stats
  # Recurring daily (config/recurring.yml): a reading that expired stops counting as verified on its own (the
  # unexpired scope), but the podcast's denormalized columns (downloads_per_episode, downloads_trust, which the
  # directory and the brand search filter on) and its page caches still hold it. This refreshes them for each podcast
  # with a reading that expired since about the last run. Running it twice does no harm.
  class ExpireReadingsJob < ApplicationJob
    queue_as :stats
    queue_with_priority 10

    # A little more than a day, so a late or skipped run misses nothing.
    LOOKBACK = 2.days

    def perform(now = Time.current)
      podcast_ids = StatReading.where(expires_at: (now - LOOKBACK)..now).distinct.pluck(:podcast_id)
      Podcast.where(id: podcast_ids).find_each do |podcast|
        podcast.refresh_plays_per_episode!(now)
        podcast.refresh_listing!
        podcast.touch
      end
    end
  end
end
