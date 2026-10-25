# The ownership code for a show, sent to the owner address in its RSS feed.
class VerificationMailer < ApplicationMailer
  # The code is made here, while the queued email renders, so it is never stored in the job queue or logged.
  # A request that was retired (a newer code was asked for) or used before the job ran sends nothing.
  def code
    @verification = params[:verification]
    @show = @verification.show
    @code = @verification.issue_code!
    return unless @code

    mail to: @verification.sent_to, subject: "Your #{APP_NAME} code for #{@show.title}"
  end
end
