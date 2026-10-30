module Sponsors
  # Finds the sponsor reads in a podcast's episodes (Sponsors::Scan) and saves them (Sponsors::Record): brands,
  # SponsorMentions, episodes marked checked. Catalog::Ingest queues it for new episodes; the daily sweep and
  # `bin/rails sponsors:scan_unscanned` queue it for episodes still due.
  #
  # Of the episodes it is given it reads only the due ones (Sponsors::Due): an active podcast's, never checked by the
  # model, published inside the window, at most sponsors_max_per_podcast of them, the newest first. Older episodes are
  # left alone. rescan: true (`bin/rails sponsors:rescan[slug]`, an admin's deliberate choice) reads every episode given,
  # of any podcast but a removed one, and replaces what the model said before.
  #
  # Idempotent: it re-reads the podcast and episodes, one run per podcast at a time, and a second run finds nothing
  # due. While today's catalog budget can't pay for a call it does nothing at all; episodes whose check was skipped
  # mid-run (budget spent, provider down) stay due for a later run, and the run itself never fails for that.
  class ScanJob < ApplicationJob
    queue_as :sponsors
    queue_with_priority 20
    limits_concurrency to: 1, key: ->(podcast_id, *) { podcast_id }, duration: 10.minutes

    # The most episodes one run takes (ingest stores the newest 50 per fetch).
    MAX_EPISODES = 100

    def perform(podcast_id, episode_ids, rescan: false)
      podcast = Podcast.find_by(id: podcast_id)
      return if podcast.nil? || podcast.removed? || !(rescan || podcast.active?)
      return unless Llm.fake? || LlmCheck.affordable?

      episodes = podcast.episodes.where(id: Array(episode_ids).first(MAX_EPISODES))
      episodes = (rescan ? episodes : Due.for_run(episodes)).to_a
      return if episodes.empty?

      Record.call(podcast, Scan.call(podcast, episodes))
    end
  end
end
