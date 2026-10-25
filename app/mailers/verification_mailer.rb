# The ownership code for a show, sent to the owner address in its RSS feed.
class VerificationMailer < ApplicationMailer
  # The title comes from the feed, which anyone can host, so it is cut short in the subject and the body.
  TITLE_LIMIT = 60

  # The code is made here, while the queued email renders, so it is never stored in the job queue or logged.
  # A request that was retired (a newer code was asked for) or used before the job ran sends nothing.
  def code
    @verification = params[:verification]
    @title = @verification.show.title.to_s.squish.truncate(TITLE_LIMIT)
    @code = @verification.issue_code!
    return unless @code

    mail to: @verification.sent_to, subject: "Your #{APP_NAME} code for #{@title}"
  end
end
