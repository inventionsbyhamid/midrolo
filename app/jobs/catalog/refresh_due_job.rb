module Catalog
  # Recurring every 10 minutes (config/recurring.yml): leases the podcasts due for a feed check, 200 at a time, and
  # queues their ingest. The lease (podcasts.leased_until, taken with FOR UPDATE SKIP LOCKED) keeps a second refresh,
  # or a second worker, off the same podcasts until the ingest frees it, or it runs out. Feeds on one host are spaced
  # a few seconds apart, and at most MAX_PER_HOST a run go to one host; the rest wait for the next run.
  class RefreshDueJob < ApplicationJob
    queue_as :catalog

    BATCH = 200
    LEASE = 1.hour
    HOST_SPACING = 3.seconds
    MAX_PER_HOST = 50

    def perform
      now = Time.current
      held_back = []
      lease(now).group_by { |_id, feed_url| Detection.host_of(feed_url) }.each_value do |podcasts|
        queued, waiting = podcasts.map(&:first).partition.with_index { |_id, index| index < MAX_PER_HOST }
        queued.each_with_index do |id, index|
          IngestPodcastJob.set(wait: HOST_SPACING * index, priority: Podcast::INGEST_PRIORITIES.fetch(:normal)).perform_later(id)
        end
        held_back.concat(waiting)
      end
      Podcast.where(id: held_back).update_all(leased_until: nil) if held_back.any?
    end

    private

    # [[id, feed_url], ...] of the due podcasts this run took, oldest due first.
    def lease(now)
      Podcast.transaction do
        due = Podcast.due_for_fetch(now).limit(BATCH).lock("FOR UPDATE SKIP LOCKED").pluck(:id, :feed_url)
        Podcast.where(id: due.map(&:first)).update_all(leased_until: now + LEASE) if due.any?
        due
      end
    end
  end
end
