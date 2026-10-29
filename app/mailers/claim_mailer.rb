# Mail about claiming a podcast (lane L4).
#   access_request  someone asked a claimed show's owner for access (Claims::AccessRequest). It goes to the owner's
#                   account address, never the feed's, and replies go straight to the person who asked.
class ClaimMailer < ApplicationMailer
  # The title comes from the feed, which anyone can host, so it is cut short, as in VerificationMailer.
  TITLE_LIMIT = VerificationMailer::TITLE_LIMIT

  def access_request
    @podcast = params[:podcast]
    @requester = params[:requester]
    owner = @podcast.owner_show&.user
    return if owner&.email.blank? || @requester.email.blank?

    @title = @podcast.title.to_s.squish.truncate(TITLE_LIMIT)
    @name = @requester.name.to_s.squish.truncate(80).presence || "Someone"
    mail to: owner.email, reply_to: @requester.email, subject: "#{@name} asked for access to #{@title} on #{APP_NAME}"
  end
end
