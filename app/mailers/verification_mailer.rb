# Mail about verifying a show.
#   code       the ownership code, sent to the owner address in the show's RSS feed.
#   verified   a background check found the feed token (Verifications::WatchFeedJob): the show is verified and the
#              line can go. A press that verifies says so on the page instead.
#   not_found  the watch after a failed check ran out without finding the token.
# The last two go to the show's user, the account that asked for the token.
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

  def verified
    return unless (to = owner_address)

    mail to: to, subject: "#{@title} is verified on #{APP_NAME}"
  end

  def not_found
    return unless (to = owner_address)

    mail to: to, subject: "We couldn't verify #{@title} yet"
  end

  private

  # The show's user's address, with the show and its title set for the mail; nil when the account has none.
  def owner_address
    @show = params[:verification].show
    @title = @show.title.to_s.squish.truncate(TITLE_LIMIT)
    @show.user&.email.presence
  end
end
