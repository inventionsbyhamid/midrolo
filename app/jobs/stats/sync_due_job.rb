module Stats
  # Recurring every 15 minutes (config/recurring.yml): enqueues Stats::SyncJob for each connection that is due, on the
  # platforms whose service session works (the rest wait for an admin). Due means:
  #
  #   pending_invite  backing off with its age: every run for its first 2 hours, then hourly until a
  #                   day old, then every 6 hours (SyncJob turns one older than StatConnection::INVITE_WINDOW into
  #                   failed), so a pile of invites nobody accepted doesn't run the helper against the platforms all day
  #                   (code review M6). "I've invited Midrolo" and Check now sync at once, whatever the backoff.
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
    # Pending invites back off with age: checked every run while younger than EVERY_RUN, hourly while younger than
    # HOURLY, then every LATER_WAIT.
    EVERY_RUN = 2.hours
    HOURLY = 24.hours
    LATER_WAIT = 6.hours
    # Runs come every 15 minutes and a check lands a little after its run, so a wait is measured this much short.
    SLACK = 5.minutes

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
      pending(connections, now).or(active).or(failed).or(mismatched).select(:id)
    end

    # Pending invites whose wait (by their age) has passed since their last check.
    def pending(connections, now)
      invites = connections.pending_invite
      young = invites.where(created_at: (now - EVERY_RUN)..)
      first_day = checked_before(invites.where(created_at: (now - HOURLY)...(now - EVERY_RUN)), now - 1.hour)
      later = checked_before(invites.where(created_at: ...(now - HOURLY)), now - LATER_WAIT)
      young.or(first_day).or(later)
    end

    def checked_before(scope, time)
      scope.where("stat_connections.last_checked_at IS NULL OR stat_connections.last_checked_at < ?", time + SLACK)
    end
  end
end
