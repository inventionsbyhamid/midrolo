# Shared run loop for report jobs: running, then done, or failed (keeping any saved sections).
class ReportJob < ApplicationJob
  queue_as :default

  def perform(report_id)
    report = Report.find_by(id: report_id)
    return unless report&.queued?

    report.mark_running!
    Research::Run.call(report)
    # The engine may have finished the report itself (for example as needs_input).
    report.mark_done! if report.reload.running?
  rescue StandardError, NotImplementedError => e
    Rails.logger.error("#{self.class.name} report=#{report_id} failed: #{e.class}: #{e.message}")
    report&.mark_failed!
  end
end
