module Catalog
  # One step of the paced seed (catalog:seed_paced): reads ONE Qloo page of Catalog::SeedFromQloo (one recommend call,
  # then its entities matched with the directory pacing), records the progress (Catalog::SeedProgress), and queues
  # itself again after the interval, until the target is linked, the tags run out, or Qloo's caps stop it.
  #
  # state is plain job arguments, no secrets: "chain" (the run's id), "target", "finish_by", "interval" (seconds),
  # and the cursor ("tag_index", "offset", "exhausted"). A step whose chain is no longer the running one (stopped by
  # hand, or replaced after a stall) does nothing. An unexpected error is reported and the same page is tried again
  # after the interval, at most MAX_ERRORS times in a row.
  class SeedStepJob < ApplicationJob
    queue_as :catalog
    queue_with_priority Podcast::INGEST_PRIORITIES.fetch(:low)
    # One page at a time, whatever happens to the schedule.
    limits_concurrency to: 1, key: ->(_state) { "catalog_seed_paced" }, duration: 30.minutes

    MAX_ERRORS = 3

    def perform(state)
      state = state.to_h.stringify_keys
      progress = SeedProgress.current
      return unless progress && progress.status == "running" && progress.chain == state["chain"]

      step, error = read_page(state)
      now = Time.current
      if error
        retry_later(progress, state, error, now)
      elsif step.stopped
        progress.record!(step, now: now)
      else
        interval = SeedProgress.interval_for(remaining: state["target"].to_i - step.linked, finish_by: finish_by(state, now),
                                             pages: progress.pages.to_i + 1, matched: progress.matched.to_i + step.matched,
                                             now: now)
        progress.record!(step, now: now, interval: interval)
        self.class.set(wait: interval.seconds).perform_later(state.merge(step.cursor.to_h, "interval" => interval, "errors" => 0))
      end
    end

    private

    def read_page(state)
      cursor = SeedFromQloo::Cursor.from_h(state)
      [ SeedFromQloo.read_page(cursor, target: state["target"].to_i, log: ->(line) { logger.info("[#{self.class.name}] #{line}") }), nil ]
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { job: self.class.name, chain: state["chain"], cursor: cursor&.to_h })
      [ nil, "#{e.class.name}: #{e.message}".first(200) ]
    end

    def retry_later(progress, state, error, now)
      errors = state["errors"].to_i + 1
      return progress.fail!(now: now, error: error) if errors >= MAX_ERRORS

      interval = state["interval"].to_i.clamp(SeedProgress::MIN_INTERVAL.to_i, SeedProgress::MAX_INTERVAL.to_i)
      progress.record!(nil, now: now, interval: interval, error: error)
      self.class.set(wait: interval.seconds).perform_later(state.merge("errors" => errors))
    end

    def finish_by(state, now)
      Time.zone.parse(state["finish_by"].to_s) || now
    end
  end
end
