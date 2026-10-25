# Mails a full report's owner that it's ready (UserMailer.report_ready), DELAY after it finished, unless they opened it
# since (Report#ready_email_due?). ReportJob queues it when a full report is done.
class ReportReadyMailJob < ApplicationJob
  DELAY = 2.minutes

  queue_as :default

  def perform(report_id)
    report = Report.includes(show: :user).find_by(id: report_id)
    UserMailer.report_ready(report).deliver_now if report&.ready_email_due?
  end
end
