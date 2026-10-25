# The lifecycle emails (Task 20), each with one next action:
#   welcome        after the first sign in (Users::OmniauthCallbacksController)
#   report_ready   a full report finished while its owner was away (ReportReadyMailJob)
#   runs_resumed   new runs are back, for the notify list (RunsResumedMailJob, R81)
class UserMailer < ApplicationMailer
  # The show title comes from the feed, which anyone can host, so it is cut short, as in VerificationMailer.
  TITLE_LIMIT = VerificationMailer::TITLE_LIMIT

  helper ReportsHelper # best_fits and and_list, as At a glance has them

  def welcome(user)
    return if user.email.blank?

    @first_name = user.name.to_s.split.first
    mail to: user.email, subject: "Welcome to #{APP_NAME}"
  end

  # A full report shows its owner every match, so naming the best fits gives nothing away.
  def report_ready(report)
    @report = report
    @show = report.show
    @title = @show.title.to_s.squish.truncate(TITLE_LIMIT)
    @matches = report.sponsor_matches.to_a
    mail to: @show.user.email, subject: "Your sponsor report for #{@title} is ready"
  end

  def runs_resumed(entry)
    mail to: entry.email, subject: "New reports are back on #{APP_NAME}"
  end
end
