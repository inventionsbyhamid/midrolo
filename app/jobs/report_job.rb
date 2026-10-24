# Shared run loop for report jobs: running, then done, or failed (keeping any saved sections).
class ReportJob < ApplicationJob
  queue_as :default

  def perform(report_id)
    report = Report.find_by(id: report_id)
    return unless report&.queued?

    begin
      report.mark_running!
      Research::Run.call(report)
      # The engine may have finished the report itself (for example as needs_input).
      report.mark_done! if report.reload.running?
    rescue StandardError, NotImplementedError => e
      Rails.error.report(e, handled: true, context: { report_id: report_id, job: self.class.name })
      fail_report(report)
    ensure
      # Anything else (SIGTERM during a deploy, Interrupt) must not leave the report running forever.
      fail_report(report) if report.reload.active?
    end
  end

  private

  def fail_report(report)
    report.reload.mark_failed! if report.reload.active?
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { report_id: report.id, while: "marking failed" })
  end
end
