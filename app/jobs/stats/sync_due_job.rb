module Stats
  # Stub (lane L5 fills it), recurring every 15 minutes (config/recurring.yml): enqueues Stats::SyncJob for each
  # pending invite (for up to StatConnection::INVITE_WINDOW) and each active connection not synced today.
  class SyncDueJob < ApplicationJob
    queue_as :stats
    queue_with_priority 10

    def perform; end
  end
end
