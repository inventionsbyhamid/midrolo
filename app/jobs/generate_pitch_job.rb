# Writes one queued pitch (Pitches::Writer) and always ends it done or failed; Pitch broadcasts the result into the
# open dialog. Transient provider or network errors are retried here a few times (RubyLLM already retries each
# request); a refused budget never is. A failed pitch isn't counted toward the plan's limit (R50).
class GeneratePitchJob < ApplicationJob
  queue_as :default

  TRANSIENT = [
    RubyLLM::RateLimitError, RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError,
    Faraday::TimeoutError, Faraday::ConnectionFailed
  ].freeze
  # Seconds to wait before each retry; one more attempt than waits.
  RETRY_WAITS = [ 2, 5 ].freeze
  ATTEMPTS = RETRY_WAITS.size + 1

  def perform(pitch_id)
    pitch = Pitch.find_by(id: pitch_id)
    return unless pitch&.queued?
    return pitch.mark_failed! if pitch.stale? # shown as failed already; don't write it late

    begin
      pitch.complete!(write(pitch), model: Llm.fake? ? "fake" : Llm.pitch_model)
    rescue Llm::BudgetExceeded
      pitch.mark_failed!(Pitch::PAUSED_MESSAGE)
    rescue Pitches::Writer::Rejected
      pitch.mark_failed!(Pitch::UNGROUNDED_MESSAGE)
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { pitch_id: pitch_id, job: self.class.name })
      fail_pitch(pitch_id)
    ensure
      # Anything else (SIGTERM during a deploy, Interrupt) must not leave the pitch queued forever.
      fail_pitch(pitch_id)
    end
  end

  private

  def write(pitch)
    attempt = 0
    begin
      attempt += 1
      Pitches::Writer.call(pitch.sponsor_match, pitch: pitch)
    rescue *TRANSIENT
      raise if attempt >= ATTEMPTS

      sleep RETRY_WAITS[attempt - 1]
      retry
    end
  end

  def fail_pitch(pitch_id)
    current = Pitch.find_by(id: pitch_id)
    current.mark_failed! if current&.queued?
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { pitch_id: pitch_id, while: "marking failed" })
  end
end
