module Sponsors
  # Stub (lane L2 fills it): finds sponsor reads in a podcast's new episodes (Sponsors::Scan), saves SponsorMentions
  # and marks the episodes sponsor_scanned_at.
  class ScanJob < ApplicationJob
    queue_as :sponsors
    queue_with_priority 20

    def perform(podcast_id, episode_ids); end
  end
end
