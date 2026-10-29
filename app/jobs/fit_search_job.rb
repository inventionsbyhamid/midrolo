# Runs one queued fit search (FitSearch::Run) on the reports queue, beside the podcaster's reports, and always ends it
# done or failed. The start is claimed first, so a job delivered twice runs the search once; a background job may
# wait out Qloo's minute cap (Taste::CallGuard.waiting) where a web request never does.
class FitSearchJob < ApplicationJob
  queue_as :reports

  def perform(fit_search_id)
    search = FitSearch.find_by(id: fit_search_id)
    return unless search && claim_start(search)

    begin
      Taste::CallGuard.waiting { FitSearch::Run.call(search) }
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { fit_search_id: search.id, job: self.class.name })
      fail_search(search)
    ensure
      # Anything else (SIGTERM during a deploy) must not leave the search running forever.
      fail_search(search)
    end
  end

  private

  # queued => running for exactly one delivery of this job.
  def claim_start(search)
    now = Time.current
    claimed = FitSearch.where(id: search.id, status: "queued").update_all(status: "running", started_at: now, updated_at: now)
    return false unless claimed == 1

    search.reload
    FitSearch::Broadcast.refresh(search)
    true
  end

  def fail_search(search)
    current = FitSearch.find_by(id: search.id)
    return unless current&.active?

    current.update!(status: "failed", finished_at: Time.current, error_message: FitSearch::Run::FAILURE_MESSAGE)
    FitSearch::Broadcast.refresh(current)
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { fit_search_id: search.id, while: "marking failed" })
  end
end
