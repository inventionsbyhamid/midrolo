module Stats
  # Recurring every 15 minutes (config/recurring.yml): enqueues Stats::SyncJob for each connection that is due, on the
  # platforms whose service session works (the rest wait for an admin). Due means:
  #
  #   pending_invite  every run (SyncJob turns one older than StatConnection::INVITE_WINDOW into failed)
  #   active          not synced in the last DAILY, and not checked in the last RETRY
  #   failed          once activated, checked again daily (an invite that lapsed waits for the owner instead)
  #   mismatch        checked again daily while the invite window lasts, or once it had been active
  #
  # SyncJob's concurrency limit drops a second sync of a connection that is still queued or running.
  class SyncDueJob < ApplicationJob
    queue_as :stats
    queue_with_priority 10

    DAILY = 20.hours
    RETRY = 1.hour
    BATCH = 500

    def perform(now = Time.current)
      platforms = ::Stats::ServiceSessions.working_platforms
      return if platforms.empty?

      due(platforms, now).find_each(batch_size: BATCH) { |connection| SyncJob.perform_later(connection.id) }
    end

    private

    def due(platforms, now)
      connections = StatConnection.where(provider: platforms)
      active = connections.active.where("last_synced_at IS NULL OR last_synced_at < ?", now - DAILY)
                          .where("last_checked_at IS NULL OR last_checked_at < ?", now - RETRY)
      retried = connections.where(status: %w[failed mismatch]).where("last_checked_at IS NULL OR last_checked_at < ?", now - DAILY)
      failed = retried.failed.where.not(activated_at: nil)
      mismatched = retried.mismatch.where(activated_at: nil).where(created_at: (now - StatConnection::INVITE_WINDOW)..)
                          .or(retried.mismatch.where.not(activated_at: nil))
      connections.pending_invite.or(active).or(failed).or(mismatched).select(:id)
    end
  end
end
