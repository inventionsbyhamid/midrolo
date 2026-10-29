module Stats
  # Stub (lane L5 fills it): reads one stats connection's numbers through Stats::PlatformFetch, saves them as
  # StatReadings, moves the connection's status along (pending_invite, active, mismatch, failed, disconnected) and
  # refreshes the podcast's listing columns (Podcast#refresh_listing!).
  class SyncJob < ApplicationJob
    queue_as :stats
    queue_with_priority 10

    def perform(connection_id); end
  end
end
