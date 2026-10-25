# Writes one queued pitch (Pitches::Writer) and always ends it done or failed; Pitch broadcasts the result into the
# open dialog. A failed pitch isn't counted toward the plan's limit (R50).
#
# Transient provider or network errors re-enqueue the job with a wait (retry_on), up to ATTEMPTS runs in all, so no
# worker thread sleeps; the pitch stays queued, and reserved, for the next run. Every run first fails a pitch that
# went stale meanwhile instead of writing it late. A refused budget is never retried. Each run claims the pitch
# before writing (R135), so a second delivery of the job writes nothing; a retry gives the claim back for the next run.
class GeneratePitchJob < ApplicationJob
  queue_as :default

  TRANSIENT = [
    RubyLLM::RateLimitError, RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError,
    Faraday::TimeoutError, Faraday::ConnectionFailed
  ].freeze
  ATTEMPTS = 3
  RETRY_WAIT = 5.seconds

  # After the last attempt perform's ensure has already failed the pitch: report the error and stop.
  retry_on(*TRANSIENT, attempts: ATTEMPTS, wait: RETRY_WAIT) do |job, error|
    Rails.error.report(error, handled: true, context: { pitch_id: job.arguments.first, job: job.class.name })
  end

  def perform(pitch_id)
    pitch = Pitch.find_by(id: pitch_id)
    return unless pitch&.queued?
    return pitch.mark_failed! if pitch.stale? # shown as failed already; don't write it late
    return unless pitch.claim_start!

    retrying = false
    begin
      pitch.complete!(Pitches::Writer.call(pitch.sponsor_match, pitch: pitch), model: Llm.fake? ? "fake" : Llm.pitch_model)
    rescue *TRANSIENT
      retrying = executions < ATTEMPTS # retry_on enqueues the next run; the pitch stays queued for it
      pitch.release_start! if retrying
      raise
    rescue Llm::BudgetExceeded
      pitch.mark_failed!(Pitch::PAUSED_MESSAGE)
    rescue Pitches::Writer::Ungrounded
      pitch.mark_failed!(Pitch::UNGROUNDED_MESSAGE)
    rescue Pitches::Writer::Malformed, Pitches::Writer::Stale
      pitch.mark_failed!
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { pitch_id: pitch_id, job: self.class.name })
      fail_pitch(pitch_id)
    ensure
      # Anything else (SIGTERM during a deploy, Interrupt, the last transient error) must not leave the pitch queued.
      fail_pitch(pitch_id) unless retrying
    end
  end

  private

  def fail_pitch(pitch_id)
    current = Pitch.find_by(id: pitch_id)
    current.mark_failed! if current&.queued?
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { pitch_id: pitch_id, while: "marking failed" })
  end
end
