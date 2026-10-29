module Stats
  # The audience over the last 12 months, for an active connection whose 30 days gave no breakdown (a small show's
  # month is often too few listens; coordinator ruling, 2026-10-30). Stats::SyncJob enqueues it. It is one more helper
  # run, so it goes through Stats::Throttle like any other and waits (re-enqueued) when the platform's limits say so;
  # and it runs at most once a week per connection (due?), since a year of listens barely moves in a week. It saves
  # only the audience reading (Stats::Record.audience); a call that fails keeps the last one.
  class AudienceJob < ApplicationJob
    queue_as :stats
    queue_with_priority 20 # after the daily syncs
    limits_concurrency to: 1, key: ->(connection_id) { "audience-#{connection_id}" }, duration: 5.minutes,
                       on_conflict: :discard

    WEEK = 7.days

    # No 12-month call for this connection in the last WEEK: none saved an audience over a year (durable), and none
    # was tried (whatever came back; a mark in the shared cache, so a call that keeps failing is also weekly).
    def self.due?(connection, now = Time.current)
      return false if Rails.cache.exist?(tried_key(connection))

      !StatReading.where(podcast_id: connection.podcast_id, source: connection.provider,
                         metric: "#{connection.provider}_audience", period_days: ::Stats::PlatformFetch::AUDIENCE_DAYS..)
                  .where("captured_at > ?", now - WEEK).exists?
    end

    def self.tried_key(connection) = "stats:audience_tried:#{connection.id}"

    def perform(connection_id)
      connection = StatConnection.includes(:podcast).find_by(id: connection_id)
      return unless connection&.active? && ::Stats.platform?(connection.provider)
      return unless self.class.due?(connection) && ::Stats::Ownership.owner_problem(connection).nil?

      session = ServiceSession.find_by(platform: connection.provider)
      return unless session&.ok?

      slot = ::Stats::Throttle.reserve(connection.provider)
      return again(connection_id, slot.at) unless slot.allowed?

      result = ::Stats::Throttle.track(connection.provider) do
        ::Stats::PlatformFetch.call(connection, session: session, days: ::Stats::PlatformFetch::AUDIENCE_DAYS)
      end
      handle(connection, session, result)
    end

    private

    def handle(connection, session, result)
      case result["ok"] ? "ok" : result["error"]
      when "ok"
        ::Stats::ServiceSessions.worked!(session)
        tried(connection)
        save(connection, result)
      when "rate_limited" then again(connection.id, ::Stats::Throttle.later(connection.provider))
      when "expired" then ::Stats::ServiceSessions.expired!(session, result["message"]) # asked again after a new session
      when "unavailable" then nil
      else tried(connection) # the daily sync deals with lost access; the last audience stays
      end
    end

    def save(connection, result)
      return if ::Stats::Ownership.show_problem(connection, result.fetch("show", {}))
      # Rejected or removed while the platform answered: save nothing.
      return unless StatConnection.where(id: connection.id, status: "active").exists?

      ::Stats::Record.audience(connection, result)
    end

    def tried(connection) = Rails.cache.write(self.class.tried_key(connection), true, expires_in: WEEK)

    def again(connection_id, at)
      self.class.set(wait_until: [ at, SyncJob::MIN_WAIT.from_now ].max).perform_later(connection_id)
    end
  end
end
