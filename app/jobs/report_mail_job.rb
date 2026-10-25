# Mails a full report's owner its outcome, DELAY after it ended, unless they opened it since (Report#outcome_mail_due?,
# R113): UserMailer.report_ready when it's done, UserMailer.report_needs_input when it needs comparable shows. A failed
# report sends nothing. The mail is claimed (Report#claim_outcome_mail!) before it's delivered, so a job that runs
# twice sends it once. ReportJob queues it.
#
# A delivery that raises gives the claim back (R119): a network error or timeout, or Resend's 5xx or 429, is retried a
# few times with a growing wait, and a nudge lost to one blip is worse than a rare duplicate.
class ReportMailJob < ApplicationJob
  DELAY = 2.minutes
  MAILS = { "done" => :report_ready, "needs_input" => :report_needs_input }.freeze
  TRANSIENT = [
    Timeout::Error, EOFError, SocketError, OpenSSL::SSL::SSLError, Errno::ECONNREFUSED, Errno::ECONNRESET,
    Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT, Resend::Error::InternalServerError,
    Resend::Error::RateLimitExceededError
  ].freeze
  ATTEMPTS = 3

  queue_as :default

  # After the last attempt the claim is already given back: report the error and stop.
  retry_on(*TRANSIENT, attempts: ATTEMPTS, wait: :polynomially_longer) do |job, error|
    Rails.error.report(error, handled: true, context: { report_id: job.arguments.first, job: job.class.name })
  end

  def perform(report_id)
    report = Report.includes(show: :user).find_by(id: report_id)
    return unless report&.outcome_mail_due?
    return unless (claimed_at = report.claim_outcome_mail!)

    begin
      UserMailer.public_send(MAILS.fetch(report.status), report).deliver_now
    rescue Exception # rubocop:disable Lint/RescueException -- gives the claim back, then always re-raises
      report.release_outcome_mail!(claimed_at)
      raise
    end
  end
end
