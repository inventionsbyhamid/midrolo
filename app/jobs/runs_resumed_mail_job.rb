# Tells the notify list that new runs are back (R81): the paused notice promises "we'll email you when they're back".
# Admin::PausesController queues it on resume. Each entry is claimed before its mail is queued, so a second run (a
# double resume, a retry) mails nobody twice. If runs were paused again before it ran, it waits for the next resume.
class RunsResumedMailJob < ApplicationJob
  queue_as :default

  def perform
    return if AppSettings.runs_paused?

    WaitlistEntry.awaiting_notice.find_each do |entry|
      next unless WaitlistEntry.awaiting_notice.where(id: entry.id).update_all(notified_at: Time.current) == 1

      UserMailer.runs_resumed(entry).deliver_later
    end
  end
end
