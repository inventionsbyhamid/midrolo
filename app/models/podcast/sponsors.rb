# Podcast: sponsor detection and sponsor history.
# Lane L2 adds its methods here, and only here (build spec section 10), so lanes don't edit the same model file.
module Podcast::Sponsors
  extend ActiveSupport::Concern

  # Queues Sponsors::ScanJob for episode_ids, or for this run's share of the episodes due (Sponsors::Due: recent, never
  # checked by the model, the newest first). rescan: true scans the given episodes again. Returns the job, or nil when
  # there is nothing to scan.
  def scan_sponsors_later(episode_ids = nil, rescan: false)
    ids = episode_ids || ::Sponsors::Due.for_run(episodes).pluck(:id)
    ::Sponsors::ScanJob.perform_later(id, ids.to_a, rescan: rescan) if ids.present? && !removed?
  end

  # The brands that sponsored this podcast, the most recent first (Sponsors::History.for).
  def sponsor_history(limit: nil) = ::Sponsors::History.for(self, limit: limit)
end
