module Stats
  # Recurring every 15 minutes (config/recurring.yml): enqueues Stats::SyncJob for each connection that is due, on the
  # platforms whose service session works (the rest wait for an admin). Due means:
  #
  #   pending_invite  backing off with its age: every run for its first 2 hours, then hourly until a
  #                   day old, then every 6 hours (SyncJob turns one older than StatConnection::INVITE_WINDOW into
  #                   failed), so a pile of invites nobody accepted doesn't run the helper against the platforms all day
  #                   (code review M6). "I've invited Midrolo" and Check now sync at once, whatever the backoff.
  #   active          once a day at its own minute (daily_minute: a stable spread of its id over the day), so the day's
  #                   syncs land a few per run instead of all in one: due once that minute has passed since it last
  #                   synced, and not synced in the last MIN_DAILY_GAP; a failing one is retried after RETRY
  #   failed          once activated, checked again daily at its minute (an invite that lapsed waits for the owner)
  #   mismatch        checked again daily at its minute while the invite window lasts, or once it had been active
  #
  # Per platform it enqueues no more than Stats::Throttle can run before the next pass (Throttle.room: none while the
  # platform cools down or has used its hour or day), people waiting first: pending invites, then active connections,
  # then the rest, the longest unchecked first. What doesn't fit stays due for the next pass. SyncJob's concurrency
  # limit drops a second sync of a connection that is still queued or running.
  class SyncDueJob < ApplicationJob
    queue_as :stats
    queue_with_priority 10

    INTERVAL = 15.minutes # how often config/recurring.yml runs this
    MIN_DAILY_GAP = 12.hours
    RETRY = 1.hour
    # Pending invites back off with age: checked every run while younger than EVERY_RUN, hourly while younger than
    # HOURLY, then every LATER_WAIT.
    EVERY_RUN = 2.hours
    HOURLY = 24.hours
    LATER_WAIT = 6.hours
    # Runs come every 15 minutes and a check lands a little after its run, so a wait is measured this much short.
    SLACK = 5.minutes
    # Spreads ids over the 1440 minutes of a day: about 1440 divided by the golden ratio and sharing no factor with
    # 1440, so every minute belongs to one id in 1440 and consecutive ids land far apart (96 in a row fall into 86
    # different 15-minute runs, at most 2 in one).
    SPREAD = 889
    MINUTES_A_DAY = 1440
    # "Its minute has come since <column>, and <column> isn't recent", for the two columns daily checks look at.
    SLOT_SQL = "(CAST(:today AS timestamp) + ((stat_connections.id * #{SPREAD}) % #{MINUTES_A_DAY}) * INTERVAL '1 minute')".freeze
    LATEST_SLOT_SQL = "(CASE WHEN #{SLOT_SQL} <= CAST(:now AS timestamp) THEN #{SLOT_SQL} ELSE #{SLOT_SQL} - INTERVAL '1 day' END)".freeze
    DAILY_SQL = %w[last_synced_at last_checked_at].to_h do |column|
      [ column.to_sym, "stat_connections.#{column} IS NULL OR (stat_connections.#{column} < #{LATEST_SLOT_SQL} " \
                       "AND stat_connections.#{column} < :recent)" ]
    end.freeze
    ORDER = Arel.sql("CASE stat_connections.status WHEN 'pending_invite' THEN 0 WHEN 'active' THEN 1 ELSE 2 END, " \
                     "stat_connections.last_checked_at ASC NULLS FIRST, stat_connections.id")

    # The minute of the day (UTC, 0 to 1439) a connection's daily sync is due at.
    def self.daily_minute(connection_id) = (connection_id * SPREAD) % MINUTES_A_DAY

    def perform(now = Time.current)
      ::Stats::ServiceSessions.working_platforms.each do |platform|
        room = ::Stats::Throttle.room(platform, within: INTERVAL, now: now)
        next if room.zero?

        due(platform, now).reorder(ORDER).limit(room).pluck(:id).each { |id| SyncJob.perform_later(id) }
      end
    end

    private

    def due(platform, now)
      connections = StatConnection.where(provider: platform)
      active = daily(connections.active, :last_synced_at, now)
               .where("stat_connections.last_checked_at IS NULL OR stat_connections.last_checked_at < ?", now - RETRY)
      retried = daily(connections.where(status: %w[failed mismatch]), :last_checked_at, now)
      failed = retried.failed.where.not(activated_at: nil)
      mismatched = retried.mismatch.where(activated_at: nil).where(created_at: (now - StatConnection::INVITE_WINDOW)..)
                          .or(retried.mismatch.where.not(activated_at: nil))
      pending(connections, now).or(active).or(failed).or(mismatched)
    end

    # Connections whose minute of the day has come since `column` (last synced or checked), and not within
    # MIN_DAILY_GAP of it: once a day each, each at its own time.
    def daily(scope, column, now)
      scope.where(DAILY_SQL.fetch(column), today: now.utc.beginning_of_day, now: now.utc, recent: now - MIN_DAILY_GAP)
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
