module Sponsors
  # Finds the sponsor reads in a podcast's episodes (Sponsors::Scan) and saves them (Sponsors::Record): brands,
  # SponsorMentions, episodes marked sponsor_scanned_at. Catalog::IngestPodcastJob queues it for new episodes;
  # `bin/rails sponsors:scan` queues it for episodes not scanned yet.
  #
  # Idempotent: it re-reads the podcast and episodes, skips ones already scanned unless rescan: true, and a second run
  # writes the same rows. A removed podcast is never scanned. Episodes whose model check was skipped (catalog budget
  # spent, provider down) stay unscanned for a later run; the run itself never fails for that.
  class ScanJob < ApplicationJob
    queue_as :sponsors
    queue_with_priority 20

    # A podcast keeps at most this many episodes per run (ingest stores the newest 50 per fetch).
    MAX_EPISODES = 100

    def perform(podcast_id, episode_ids, rescan: false)
      podcast = Podcast.find_by(id: podcast_id)
      return if podcast.nil? || podcast.removed?

      episodes = podcast.episodes.where(id: Array(episode_ids).first(MAX_EPISODES))
      episodes = episodes.where(sponsor_scanned_at: nil) unless rescan
      episodes = episodes.to_a
      return if episodes.empty?

      Record.call(podcast, Scan.call(podcast, episodes))
    end
  end
end
