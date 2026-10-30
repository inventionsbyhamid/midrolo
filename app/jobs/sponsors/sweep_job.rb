module Sponsors
  # The daily sponsors sweep (config/recurring.yml), and what `bin/rails sponsors:scan` runs: queues Sponsors::ScanJob
  # for up to limit active podcasts with episodes due (Sponsors::Due: recent, never checked by the model), the oldest
  # podcast first. Episodes the model check skipped for the catalog budget stay due, so the next day's sweep picks them
  # up. It first puts right brands' sponsor read counts that deletions left wrong (Sponsors::Recount, code review L9).
  # Returns how many podcasts it queued.
  class SweepJob < ApplicationJob
    queue_as :sponsors
    queue_with_priority 20

    DAILY_LIMIT = 100

    # Queues Sponsors::ScanJob for active podcasts with episodes due, up to limit (nil: every one), the oldest podcast
    # first or, with newest_first, the newest. Queues nothing while today's catalog budget can't pay for one model call
    # (the episodes stay due); without a model (fake mode) the pattern scan runs instead. Returns how many it queued.
    def self.queue_scans(limit: DAILY_LIMIT, newest_first: false)
      return 0 unless Llm.fake? || LlmCheck.affordable?

      podcasts = Due.podcasts.order(id: newest_first ? :desc : :asc)
      podcasts = podcasts.limit(limit.to_i) if limit
      podcasts.to_a.count(&:scan_sponsors_later)
    end

    def perform(limit = DAILY_LIMIT)
      Recount.call
      self.class.queue_scans(limit: limit)
    end
  end
end
