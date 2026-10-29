module Stats
  # Midrolo's own sessions on the platforms (ServiceSession): saving one an admin pasted, and what a fetch learns about
  # it. A session that stops working is marked expired once, the admins get one email, and syncs for that platform
  # pause until an admin saves a new one. Values are never logged, shown or returned.
  module ServiceSessions
    VALUE_LIMIT = 4096

    # Raised by save! with plain words for the admin form (never the values).
    class Invalid < StandardError; end

    module_function

    # Stores the pasted cookies for platform (only its keys, stripped), as working, and clears the last error.
    def save!(platform, values, expires_hint: nil)
      platform = platform.to_s
      raise Invalid, "Unknown platform." unless ::Stats.platform?(platform)

      keys = ::Stats::PLATFORMS.dig(platform, :session_keys)
      clean = values.to_h.to_h { |key, value| [ key.to_s, value.to_s.strip ] }.slice(*keys).compact_blank
      missing = ::Stats::PLATFORMS.dig(platform, :required_keys) - clean.keys
      raise Invalid, "Paste #{Copy.and_list(missing)} to save the #{::Stats.platform_name(platform)} session." if missing.any?
      raise Invalid, "A value is too long to be a cookie." if clean.values.any? { |value| value.length > VALUE_LIMIT }
      raise Invalid, "Paste each value on its own, without spaces or line breaks." if clean.values.any? { |value| value.match?(/\s/) }

      session = ServiceSession.find_or_initialize_by(platform: platform)
      session.update!(credentials: clean.to_json, status: "ok", last_error: nil, expires_hint: expires_hint)
      session
    end

    # A fetch worked with session (as it was when the fetch started).
    def worked!(session, now: Time.current)
      ServiceSession.where(id: session.id).update_all(last_ok_at: now, last_error: nil, updated_at: now)
    end

    # A fetch found session expired. Only the session that was used, unchanged since, is marked, so a session an admin
    # replaced meanwhile stays working; and only the first job to mark it sends the email.
    def expired!(session, message, now: Time.current)
      marked = ServiceSession.where(id: session.id, status: "ok", updated_at: session.updated_at)
                             .update_all(status: "expired", last_error: message.to_s.first(250), updated_at: now)
      return false if marked.zero?

      Rails.logger.warn("[Stats] the #{session.platform} service session expired; syncs for it are paused")
      AdminMailer.service_session_expired(platform: session.platform).deliver_later
      true
    end

    # The platforms whose session works, so syncs for the others wait.
    def working_platforms = ServiceSession.ok.where.not(credentials: nil).pluck(:platform)
  end
end
