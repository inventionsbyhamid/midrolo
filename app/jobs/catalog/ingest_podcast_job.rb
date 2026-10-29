module Catalog
  # Reads a podcast's feed and stores what it says (Catalog::Ingest): episodes, people, feed facts, status, the
  # indexable flag and the next fetch, then queues its artwork and the sponsor scan of new episodes. A bad feed is
  # recorded and backed off, never raised, so the queue moves on. One ingest per podcast at a time. Enqueue it through
  # Podcast#ingest_later, which sets the priority (claims and searches 0, refreshes 10, the seed 20); the artwork job
  # it queues runs at the same priority.
  class IngestPodcastJob < ApplicationJob
    queue_as :catalog
    queue_with_priority Podcast::INGEST_PRIORITIES.fetch(:normal)
    limits_concurrency to: 1, key: ->(podcast_id) { podcast_id }, duration: 5.minutes

    def perform(podcast_id)
      podcast = Podcast.find_by(id: podcast_id)
      return if podcast.nil? || podcast.removed?

      Ingest.call(podcast, priority: priority || Podcast::INGEST_PRIORITIES.fetch(:normal))
    end
  end
end
