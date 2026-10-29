module Stats
  # Keeps Midrolo's own Spotify and Apple accounts light and polite: every podcaster's connection rides on them, so a
  # flagged account would stop every connection at once. Per platform, kept on the platform's ServiceSession row and
  # changed only under that row's lock (several workers run the stats queue):
  #
  #   - one helper run at a time (a run holds a LEASE until it finishes), then a gap of Limits#min_gap seconds plus a
  #     random extra of up to Limits#jitter before the next one starts;
  #   - at most Limits#per_hour runs in any hour and Limits#per_day in any 24 hours;
  #   - after a rate-limited answer, a cooldown: the platform's Retry-After, else COOLDOWN, doubling with each
  #     rate-limited answer in a row up to COOLDOWN_MAX (never shorter than the platform asked); a run that works
  #     resets the doubling;
  #   - after FAILURE_LIMIT failed runs in a row, a pause of FAILURE_PAUSE, again after each further failure until a run
  #     works. forbidden and not_found are about one connection, not the platform, so they don't count either way.
  #
  # Callers (Stats::SyncJob, Stats::AudienceJob, the admin's test fetch) ask reserve before running the helper and run
  # it inside track, which records how it went. When a run isn't allowed yet, reserve hands back a time to come back:
  # each waiting job gets its own time, SPACING apart, so a queue drains one run at a time instead of waking at once.
  # Nothing here sleeps; jobs re-enqueue themselves for that time.
  class Throttle
    Slot = Data.define(:allowed, :at) do
      def allowed? = allowed
    end

    # For the admin page. runs_this_hour and runs_today count the last 60 minutes and the last 24 hours (the caps are
    # rolling); next_run_at is when a run may start (now when it may start now).
    Status = Data.define(:runs_this_hour, :runs_today, :next_run_at, :cooldown_until, :failures_in_a_row,
                         :last_rate_limited_at, :paused, :limits)

    COOLDOWN = 1.hour
    COOLDOWN_MAX = 24.hours
    FAILURE_LIMIT = 5
    FAILURE_PAUSE = 1.hour
    # How long a run may hold the platform before the next may start without it finishing: the helper's own timeout
    # (Stats::PlatformFetch kills it then) and a little more.
    LEASE = (Stats::PlatformFetch::TIMEOUT + 15).seconds
    # A run's usual length, added to the spacing of waiting jobs so the next one rarely wakes before its turn.
    RUN_ESTIMATE = 15.seconds
    # Outcomes that count as a failed run (any error but one about a single connection, or nothing asked).
    FAILURES = %w[failed expired rate_limited].freeze

    class << self
      # A run may start now (allowed, and recorded as started), or not yet (at: when to come back). With book: false
      # nothing is handed out, for a caller that won't come back by itself (the admin's test fetch).
      def reserve(platform, now: Time.current, book: true)
        limits = Limits.current
        slot = locked(platform) do |row|
          at = opens_at(row, now, limits)
          if at <= now
            row.update_columns(run_log: (times(row, now) << now).map(&:to_i), next_run_at: now + LEASE + gap(limits))
            Slot.new(allowed: true, at: now)
          elsif book
            Slot.new(allowed: false, at: book!(row, at, now, limits))
          else
            Slot.new(allowed: false, at: at)
          end
        end
        slot || Slot.new(allowed: true, at: now) # no session row: the helper won't be asked anything
      end

      # A time to come back for a caller that must wait (after a rate-limited answer), handed out like reserve does.
      def later(platform, now: Time.current)
        limits = Limits.current
        locked(platform) { |row| book!(row, opens_at(row, now, limits), now, limits) } || now
      end

      # Runs the block (one helper run) and records how it went, whatever happens to it.
      def track(platform)
        result = nil
        result = yield
      ensure
        finish(platform, result.is_a?(Hash) ? result : PlatformFetch.failure("failed", "The run stopped early."))
      end

      # Records a run's outcome (a Stats::PlatformFetch result): the gap starts now, and a failure or a rate limit
      # may pause the platform.
      def finish(platform, result, now: Time.current)
        limits = Limits.current
        locked(platform) do |row|
          error = result["ok"] ? nil : result["error"].to_s
          changes = { next_run_at: now + gap(limits) }
          if error.nil?
            changes.merge!(rate_limits_in_a_row: 0, failures_in_a_row: 0)
          elsif FAILURES.include?(error)
            changes[:failures_in_a_row] = row.failures_in_a_row + 1
            changes.merge!(rate_limited(row, result["retry_after"], now)) if error == "rate_limited"
            if changes[:failures_in_a_row] >= FAILURE_LIMIT
              changes[:next_run_at] = [ changes[:next_run_at], now + FAILURE_PAUSE ].max
              Rails.logger.warn("[Stats::Throttle] #{platform}: #{changes[:failures_in_a_row]} failed runs in a row, pausing an hour")
            end
          end
          row.update_columns(changes)
        end
      end

      # When the next run may start (now, or later), without handing anything out.
      def open_at(platform, now: Time.current)
        limits = Limits.current
        session = ServiceSession.find_by(platform: platform.to_s)
        session ? opens_at(session, now, limits) : now
      end

      # When a sync asked for now would run: after the platform opens and after the jobs already waiting. For "Checking
      # soon, around 14:05 UTC".
      def next_free_at(platform, now: Time.current)
        limits = Limits.current
        session = ServiceSession.find_by(platform: platform.to_s)
        return now unless session

        at = opens_at(session, now, limits)
        at <= now ? now : [ at, waiting_after(session, now, limits) ].compact.max
      end

      # How many runs fit on platform within the next `within` (for Stats::SyncDueJob, so it enqueues no more than can
      # run before its next pass): 0 while it stays shut, else the free slots, at most what the hour and day caps leave.
      def room(platform, within:, now: Time.current)
        limits = Limits.current
        session = ServiceSession.find_by(platform: platform.to_s)
        return 0 unless session

        at = opens_at(session, now, limits)
        return 0 if at > now + within

        log = times(session, now)
        free = ((now + within - [ at, now ].max) / spacing(limits).to_f).floor + 1
        [ free, limits.per_hour - log.count { |time| time > now - 1.hour }, limits.per_day - log.size ].min.clamp(0..)
      end

      def status(session, now: Time.current, limits: Limits.current)
        log = times(session, now)
        cooldown = session.cooldown_until if session.cooldown_until&.>(now)
        Status.new(runs_this_hour: log.count { |time| time > now - 1.hour }, runs_today: log.size,
                   next_run_at: opens_at(session, now, limits), cooldown_until: cooldown,
                   failures_in_a_row: session.failures_in_a_row, last_rate_limited_at: session.last_rate_limited_at,
                   paused: session.failures_in_a_row >= FAILURE_LIMIT && session.next_run_at&.>(now) || false,
                   limits: limits)
      end

      private

      # Yields the platform's session row, locked for update, and returns what the block does; nil without a row.
      def locked(platform)
        ServiceSession.transaction do
          row = ServiceSession.lock.find_by(platform: platform.to_s)
          row && yield(row)
        end
      end

      def opens_at(row, now, limits)
        log = times(row, now)
        hour = log.select { |time| time > now - 1.hour }
        candidates = [ now, row.next_run_at, row.cooldown_until ]
        candidates << hour[hour.size - limits.per_hour] + 1.hour if hour.size >= limits.per_hour
        candidates << log[log.size - limits.per_day] + 1.day if log.size >= limits.per_day
        candidates.compact.max
      end

      # The next waiting job's time: when the platform opens, or SPACING after the last one handed out.
      def book!(row, at, now, limits)
        booked = [ at, waiting_after(row, now, limits) ].compact.max
        row.update_columns(queued_until: booked)
        booked
      end

      def waiting_after(row, now, limits)
        row.queued_until + spacing(limits) if row.queued_until&.>(now)
      end

      # The start times of the runs in the last 24 hours, oldest first.
      def times(row, now)
        Array(row.run_log).filter_map { |epoch| Time.zone.at(epoch) if epoch.is_a?(Integer) }
                          .select { |time| time > now - 1.day }.sort
      end

      def gap(limits) = (limits.min_gap + rand * limits.jitter).seconds

      def spacing(limits) = (limits.min_gap + limits.jitter).seconds + RUN_ESTIMATE

      # The cooldown after a rate-limited answer: what the platform asked (else COOLDOWN), doubled for each one before
      # it in a row, at most COOLDOWN_MAX, and never shorter than the platform asked.
      def rate_limited(row, retry_after, now)
        streak = row.rate_limits_in_a_row + 1
        asked = retry_after.to_i.seconds if retry_after.is_a?(Integer) && retry_after.positive?
        wait = [ (asked || COOLDOWN) * (2**(streak - 1).clamp(0, 10)), COOLDOWN_MAX ].min
        wait = [ wait, asked ].max if asked
        Rails.logger.warn("[Stats::Throttle] rate limited: #{streak} in a row, cooling down #{wait.to_i} seconds")
        { rate_limits_in_a_row: streak, last_rate_limited_at: now, cooldown_until: now + wait }
      end
    end
  end
end
