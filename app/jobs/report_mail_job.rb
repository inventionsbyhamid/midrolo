# Mails a full report's owner its outcome, DELAY after it ended, unless they opened it since (Report#outcome_mail_due?,
# R113): UserMailer.report_ready when it's done, UserMailer.report_needs_input when it needs comparable shows. A failed
# report sends nothing. The mail is claimed (Report#claim_outcome_mail!) before it's delivered, so a job that runs
# twice sends it once. ReportJob queues it.
class ReportMailJob < ApplicationJob
  DELAY = 2.minutes
  MAILS = { "done" => :report_ready, "needs_input" => :report_needs_input }.freeze

  queue_as :default

  def perform(report_id)
    report = Report.includes(show: :user).find_by(id: report_id)
    return unless report&.outcome_mail_due? && report.claim_outcome_mail!

    UserMailer.public_send(MAILS.fetch(report.status), report).deliver_now
  end
end
