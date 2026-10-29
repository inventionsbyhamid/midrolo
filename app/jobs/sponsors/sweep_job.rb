module Sponsors
  # The daily sponsors sweep (config/recurring.yml), and what `bin/rails sponsors:scan` runs: queues Sponsors::ScanJob
  # for up to limit podcasts with episodes not scanned yet, oldest podcast first. Episodes the model check skipped for
  # the catalog budget stay unscanned, so the next day's sweep picks them up. Returns how many podcasts it queued.
  class SweepJob < ApplicationJob
    queue_as :sponsors
    queue_with_priority 20

    DAILY_LIMIT = 100

    def perform(limit = DAILY_LIMIT)
      Podcast.where.not(status: "removed").where(id: Episode.where(sponsor_scanned_at: nil).select(:podcast_id))
             .order(:id).limit(limit.to_i).count(&:scan_sponsors_later)
    end
  end
end
