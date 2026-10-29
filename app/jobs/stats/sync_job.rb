module Stats
  # Reads one stats connection's numbers through Stats::PlatformFetch and moves its status along (build spec section
  # 11). Only the connection id travels in the job; the service session is read from the database at run time.
  #
  #   pending_invite  polled (Stats::SyncDueJob, every 15 minutes) until the first fetch works, for up to
  #                   StatConnection::INVITE_WINDOW; then failed. No access yet, or no claim yet (nothing is fetched
  #                   for a podcast its maker doesn't own), just keeps it waiting.
  #   active          synced daily. Access removed (forbidden, not found) makes it disconnected; any other failure
  #                   makes it failed, retried daily.
  #   mismatch        the podcast isn't claimed by the user who connected it, or the platform's show isn't this
  #                   podcast. Nothing is saved; checked again daily and whenever the owner asks.
  #   disconnected    never polled; the owner invites Midrolo again.
  #
  # A working fetch that passes Stats::Ownership saves verified readings (Stats::Record). When the 30 days carry no
  # audience breakdown, the last audience reading stays and Stats::AudienceJob asks over the last 12 months, at most
  # weekly. An expired service session changes no connection: it marks the session expired, emails the admins once,
  # and every sync for that platform waits for a new session. Existing readings expire on their own (StatReading::TTL).
  #
  # Every helper run goes through Stats::Throttle, which keeps Midrolo's own platform accounts light (a gap between
  # runs, hourly and daily caps, a cooldown after a rate limit, a pause after failures). When a run isn't allowed yet,
  # or the platform answered "rate limited", the job enqueues itself again for the time the throttle gives: a sync is
  # never dropped and nothing waits in a worker. requested_at (when the sync was first asked for) travels along, so a
  # waiting copy that finds the connection checked since then has nothing left to do.
  class SyncJob < ApplicationJob
    queue_as :stats
    queue_with_priority 10
    # One sync per connection at a time; a second one asked for meanwhile is dropped.
    limits_concurrency to: 1, key: ->(connection_id, *) { connection_id }, duration: 5.minutes, on_conflict: :discard

    # A re-enqueued sync waits at least this long, so the copy running now has let go of the concurrency limit.
    MIN_WAIT = 5.seconds

    NO_ACCESS_YET = "We can't see this show's analytics yet. Once the invite is accepted, the numbers appear here.".freeze
    INVITE_LAPSED = "We didn't get access within 14 days. Check the invite in %<service>s, then invite Midrolo again.".freeze
    ACCESS_REMOVED = "Midrolo no longer has access to this show in %<service>s, so the numbers stopped updating. " \
                     "Invite Midrolo again to keep them verified.".freeze
    FAILED = "We couldn't read the numbers this time: %<message>s We'll try again tomorrow.".freeze

    def perform(connection_id, requested_at = nil)
      requested_at ||= enqueued_at&.to_time || Time.current
      connection = StatConnection.includes(:podcast).find_by(id: connection_id)
      return if connection.nil? || !::Stats.platform?(connection.provider) || connection.disconnected?
      return if connection.last_checked_at&.>(requested_at) # checked since this was asked for

      now = Time.current
      return lapse(connection, now) if connection.pending_invite? && connection.created_at < StatConnection::INVITE_WINDOW.ago(now)

      if (problem = ::Stats::Ownership.owner_problem(connection))
        # A pending invite waits for the claim (polling costs nothing until then); a connection that was counting stops.
        status = connection.pending_invite? ? "pending_invite" : "mismatch"
        return connection.update!(status: status, last_error: problem, last_checked_at: now)
      end

      session = ServiceSession.find_by(platform: connection.provider)
      return unless session&.ok? # paused until an admin enters a working session

      slot = ::Stats::Throttle.reserve(connection.provider)
      return again(connection_id, requested_at, slot.at) unless slot.allowed?

      result = ::Stats::Throttle.track(connection.provider) { ::Stats::PlatformFetch.call(connection, session: session) }
      handle(connection, session, result, now, requested_at)
    end

    private

    def handle(connection, session, result, now, requested_at)
      if result["ok"]
        ::Stats::ServiceSessions.worked!(session, now: now)
        return saved(connection, result, now)
      end

      case result["error"]
      when "expired" then ::Stats::ServiceSessions.expired!(session, result["message"], now: now)
      when "unavailable" then nil # the session went away mid-run; nothing to say to the podcaster
      # The platform wants fewer requests: not this connection's fault. Ask again once the cooldown is over.
      when "rate_limited" then again(connection.id, requested_at, ::Stats::Throttle.later(connection.provider))
      when "forbidden", "not_found" then no_access(connection, now)
      else failed(connection, result["message"], now)
      end
    end

    def again(connection_id, requested_at, at)
      at = [ at, MIN_WAIT.from_now ].max
      Rails.logger.info("[Stats::SyncJob] connection #{connection_id} waits for the platform's limits until #{at.utc.iso8601}")
      self.class.set(wait_until: at).perform_later(connection_id, requested_at)
    end

    def saved(connection, result, now)
      if (problem = ::Stats::Ownership.show_problem(connection, result.fetch("show", {})))
        return connection.update!(status: "mismatch", last_error: problem, last_checked_at: now)
      end
      # Disconnected (an admin's Reject) or removed (the owner's Disconnect) while the platform answered: save nothing.
      return unless StatConnection.where(id: connection.id).where.not(status: "disconnected").exists?

      no_breakdown = result.fetch("breakdowns", {}).empty?
      ::Stats::Record.call(connection, result, audience: (::Stats::Record::KEEP_LAST_AUDIENCE if no_breakdown), now: now)
      connection.update!(status: "active", activated_at: connection.activated_at || now, last_synced_at: now,
                         last_checked_at: now, last_error: nil)
      # The last 12 months, when 30 days gave no breakdown (coordinator ruling, 2026-10-30), at most once a week.
      ::Stats::AudienceJob.perform_later(connection.id) if no_breakdown && ::Stats::AudienceJob.due?(connection, now)
    end

    def no_access(connection, now)
      if connection.pending_invite?
        connection.update!(last_error: NO_ACCESS_YET, last_checked_at: now)
      else
        connection.update!(status: "disconnected", last_error: format(ACCESS_REMOVED, service: service(connection)),
                           last_checked_at: now)
      end
    end

    def failed(connection, message, now)
      text = format(FAILED, message: sentence(message))
      if connection.pending_invite?
        connection.update!(last_error: text, last_checked_at: now)
      else
        connection.update!(status: "failed", last_error: text, last_checked_at: now)
      end
    end

    def lapse(connection, now)
      connection.update!(status: "failed", last_error: format(INVITE_LAPSED, service: service(connection)), last_checked_at: now)
    end

    def service(connection) = ::Stats.service_name(connection.provider)

    def sentence(message)
      text = message.to_s.squish.first(160).presence || "the platform didn't answer."
      text.end_with?(".", "!", "?") ? text : "#{text}."
    end
  end
end
