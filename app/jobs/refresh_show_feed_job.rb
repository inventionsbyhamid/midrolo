# Reads a show's feed and stores what it learns (owner email, cadence, episode count).
# Feed problems come back as warnings from FeedReader and are ignored: the show keeps what it has.
class RefreshShowFeedJob < ApplicationJob
  queue_as :default

  def perform(show_id)
    show = Show.find_by(id: show_id)
    return unless show&.feed_url.present?

    feed = Podcasts::FeedReader.new.read(show.feed_url, max_episodes: 50)
    updates = {}
    updates[:owner_email] = feed.owner_email if feed.owner_email.present?
    updates[:cadence_days] = feed.cadence_days if feed.cadence_days.present?
    # The reader caps episodes, so only trust its count when it beats what we already know.
    updates[:episode_count] = feed.episodes.size if feed.episodes.size > show.episode_count.to_i
    show.update(updates) if updates.any?
  end
end
