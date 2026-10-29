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
  # A working fetch that passes Stats::Ownership saves verified readings (Stats::Record), and when the 30 days carry no
  # audience breakdown it asks once more over the last 12 months. An expired service session changes no connection: it
  # marks the session expired, emails the admins once, and every sync for that platform waits for a new session.
  # Existing readings expire on their own (StatReading::TTL).
  class SyncJob < ApplicationJob
    queue_as :stats
    queue_with_priority 10
    # One sync per connection at a time; a second one asked for meanwhile is dropped.
    limits_concurrency to: 1, key: ->(connection_id) { connection_id }, duration: 5.minutes, on_conflict: :discard

    NO_ACCESS_YET = "We can't see this show's analytics yet. Once the invite is accepted, the numbers appear here.".freeze
    INVITE_LAPSED = "We didn't get access within 14 days. Check the invite in %<service>s, then invite Midrolo again.".freeze
    ACCESS_REMOVED = "Midrolo no longer has access to this show in %<service>s, so the numbers stopped updating. " \
                     "Invite Midrolo again to keep them verified.".freeze
    FAILED = "We couldn't read the numbers this time: %<message>s We'll try again tomorrow.".freeze

    def perform(connection_id)
      connection = StatConnection.includes(:podcast).find_by(id: connection_id)
      return if connection.nil? || !::Stats.platform?(connection.provider) || connection.disconnected?

      now = Time.current
      return lapse(connection, now) if connection.pending_invite? && connection.created_at < StatConnection::INVITE_WINDOW.ago(now)

      if (problem = ::Stats::Ownership.owner_problem(connection))
        # A pending invite waits for the claim (polling costs nothing until then); a connection that was counting stops.
        status = connection.pending_invite? ? "pending_invite" : "mismatch"
        return connection.update!(status: status, last_error: problem, last_checked_at: now)
      end

      session = ServiceSession.find_by(platform: connection.provider)
      return unless session&.ok? # paused until an admin enters a working session

      result = ::Stats::PlatformFetch.call(connection, session: session)
      handle(connection, session, result, now)
    end

    private

    def handle(connection, session, result, now)
      if result["ok"]
        ::Stats::ServiceSessions.worked!(session, now: now)
        return saved(connection, session, result, now)
      end

      case result["error"]
      when "expired" then ::Stats::ServiceSessions.expired!(session, result["message"], now: now)
      when "unavailable" then nil # the session went away mid-run; nothing to say to the podcaster
      when "forbidden", "not_found" then no_access(connection, now)
      else failed(connection, result["message"], now)
      end
    end

    def saved(connection, session, result, now)
      if (problem = ::Stats::Ownership.show_problem(connection, result.fetch("show", {})))
        return connection.update!(status: "mismatch", last_error: problem, last_checked_at: now)
      end

      ::Stats::Record.call(connection, result, audience: longer_audience(connection, session, result), now: now)
      connection.update!(status: "active", activated_at: connection.activated_at || now, last_synced_at: now,
                         last_checked_at: now, last_error: nil)
    end

    # The last 12 months, when 30 days gave no breakdown; nil when that call fails or there was one already.
    def longer_audience(connection, session, result)
      return nil if result.fetch("breakdowns", {}).any?

      audience = ::Stats::PlatformFetch.call(connection, session: session, days: ::Stats::PlatformFetch::AUDIENCE_DAYS)
      audience if audience["ok"]
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
