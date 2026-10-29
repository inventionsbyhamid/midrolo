module Catalog
  # The paced seed (catalog:seed_paced, Catalog::SeedStepJob): Qloo's podcast pages read one at a time, spread over
  # hours, so the seed's Qloo calls, directory searches and feed reads never come in one burst. This keeps where it
  # stands in one settings row, which the admin catalog panel shows and which keeps a second chain from starting:
  #
  #   {"chain", "status" (running, finished or stopped), "target", "hours", "interval" (seconds), "pages", "matched",
  #    "added", "missed", "linked", "tag", "offset", "cursor" (where the next page is), "started_at", "finish_by",
  #    "last_run_at", "next_run_at", "stopped" (why it ended), "error"}
  #
  # A new chain picks up at the last one's cursor (stopped, stalled, capped by Qloo or ended by errors) rather than
  # reading the pages before it again; after the tags ran out it starts over.
  #
  # The interval is the time left until finish_by spread over the pages still expected: before 3 pages a guess of
  # EXPECTED_MATCHES_PER_PAGE (target / TAKE * 2, so 40 pages for 1,000 shows), then the matches a page has really
  # brought, between MIN_INTERVAL and MAX_INTERVAL. So the seed ends near finish_by whatever Qloo's match rate is.
  class SeedProgress
    KEY = "catalog_seed_paced".freeze
    DEFAULT_HOURS = 6
    EXPECTED_MATCHES_PER_PAGE = SeedFromQloo::TAKE / 2
    MIN_INTERVAL = 2.minutes
    MAX_INTERVAL = 30.minutes
    # A running chain whose next page is this late is presumed lost (its worker gone), so a new one may start; the
    # lost one, if it ever wakes, finds another chain's id and ends.
    STALL_GRACE = 1.hour
    STOP_REASONS = {
      "target" => "the target was reached", "exhausted" => "Qloo had no more podcasts in these genres",
      "qloo_limit" => "Qloo's call limit stopped it", "qloo_error" => "Qloo answered with an error",
      "error" => "it failed several times in a row", "stopped" => "it was stopped by hand"
    }.freeze

    Start = Data.define(:status, :progress) # status: :started, :running (nothing started) or :reached

    attr_reader :data

    def self.current
      value = Setting.find_by(key: KEY)&.value
      new(value) if value.is_a?(Hash)
    end

    # Starts a chain unless one is running or the target is already linked. Returns a Start; the first page is queued
    # at once.
    def self.start!(target:, hours:, now: Time.current)
      setting = Setting.find_or_create_by!(key: KEY)
      state = nil
      start = setting.with_lock do
        running = setting.value.is_a?(Hash) ? new(setting.value) : nil
        next Start.new(status: :running, progress: running) if running&.running?(now)

        linked = Podcast.where.not(qloo_entity_id: nil).count
        next Start.new(status: :reached, progress: running) if linked >= target

        finish_by = now + hours.to_f.hours
        interval = interval_for(remaining: target - linked, finish_by: finish_by, pages: 0, matched: 0, now: now)
        cursor = running&.resume_cursor || SeedFromQloo::Cursor.start(SeedFromQloo::TAGS.size)
        state = { "chain" => SecureRandom.hex(8), "target" => target, "finish_by" => finish_by.iso8601, "interval" => interval,
                  **cursor.to_h }
        setting.update!(value: { "chain" => state["chain"], "status" => "running", "target" => target, "hours" => hours.to_f,
                                 "interval" => interval, "pages" => 0, "matched" => 0, "added" => 0, "missed" => 0,
                                 "linked" => linked, "started_at" => now.iso8601, "finish_by" => finish_by.iso8601,
                                 "next_run_at" => now.iso8601, "cursor" => cursor.to_h })
        Start.new(status: :started, progress: new(setting.value))
      end
      SeedStepJob.perform_later(state) if state
      start
    end

    # Ends the running chain after the page it is on (its next step finds the status changed). False when none runs.
    def self.stop!(now: Time.current)
      progress = current
      return false unless progress&.status == "running"

      update!(progress.data.merge("status" => "stopped", "stopped" => "stopped", "next_run_at" => nil,
                                  "last_run_at" => now.iso8601))
      true
    end

    # Seconds to wait before the next page (see the class comment).
    def self.interval_for(remaining:, finish_by:, pages:, matched:, now: Time.current)
      per_page = pages >= 3 ? [ matched.to_f / pages, 1.0 ].max : EXPECTED_MATCHES_PER_PAGE
      pages_left = [ (remaining / per_page).ceil, 1 ].max
      ((finish_by - now) / pages_left).clamp(MIN_INTERVAL.to_f, MAX_INTERVAL.to_f).round
    end

    def self.update!(data)
      Setting.find_or_initialize_by(key: KEY).update!(value: data)
    end

    def initialize(data)
      @data = data.to_h.stringify_keys
    end

    %w[chain status target interval pages matched added missed linked tag offset stopped error].each do |name|
      define_method(name) { data[name] }
    end

    %w[started_at finish_by last_run_at next_run_at].each do |name|
      define_method(name) { (value = data[name]).present? ? Time.zone.parse(value) : nil }
    end

    def running?(now = Time.current) = status == "running" && !stalled?(now)

    def stalled?(now = Time.current) = status == "running" && next_run_at.present? && next_run_at + STALL_GRACE < now

    def stop_reason = STOP_REASONS.fetch(stopped.to_s, stopped.to_s.humanize.downcase)

    # Where a new chain picks up: this one's next page, unless the tags ran out (or it never read one).
    def resume_cursor
      cursor = SeedFromQloo::Cursor.from_h(data["cursor"]) if data["cursor"].is_a?(Hash)
      cursor unless cursor.nil? || cursor.finished? || stopped == "exhausted"
    end

    # After a page: the counts so far, and when the next page runs (nil when the chain ended with step.stopped).
    def record!(step, now:, interval: nil, error: nil)
      ended = step&.stopped
      merged = data.merge("pages" => pages.to_i + (step ? 1 : 0), "last_run_at" => now.iso8601, "error" => error)
      if step
        merged.merge!("matched" => matched.to_i + step.matched, "added" => added.to_i + step.added,
                      "missed" => missed.to_i + step.missed, "linked" => step.linked, "tag" => step.tag,
                      "offset" => step.cursor.offset, "cursor" => step.cursor.to_h)
      end
      merged.merge!("status" => "finished", "stopped" => ended, "next_run_at" => nil) if ended
      merged.merge!("interval" => interval, "next_run_at" => (now + interval).iso8601) unless ended || interval.nil?
      self.class.update!(merged)
      @data = merged
      self
    end

    # Ends the chain without a page (repeated errors).
    def fail!(now:, error:)
      merged = data.merge("status" => "finished", "stopped" => "error", "error" => error, "next_run_at" => nil,
                          "last_run_at" => now.iso8601)
      self.class.update!(merged)
      @data = merged
      self
    end
  end
end
