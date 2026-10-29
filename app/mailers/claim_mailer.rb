# Mail about claiming a podcast (lane L4).
#   access_request    someone asked a claimed show's owner for access (Claims::AccessRequest). It goes to the owner's
#                     account address, never the feed's, and replies go straight to the person who asked.
#   feed_unreachable  Midrolo couldn't read a claimed show's feed several times in a row (Catalog::Ingest); the show
#                     stays listed, and its owner hears once a run of failures.
#   feed_moved        the owner show's feed moved for good, so its claim was released until the owner verifies the new
#                     feed (Catalog::FeedMove). It goes to the owner's account address.
class ClaimMailer < ApplicationMailer
  helper CatalogHelper

  # The title comes from the feed, which anyone can host, so it is cut short, as in VerificationMailer.
  TITLE_LIMIT = VerificationMailer::TITLE_LIMIT
  # The new feed address comes from the feed too.
  URL_LIMIT = 200
  FEED_MOVED_SUBJECT = "Your show's feed moved; verify it again".freeze

  def feed_unreachable
    @podcast = params[:podcast]
    owner = @podcast.owner_show&.user
    return if owner&.email.blank?

    @title = @podcast.title.to_s.squish.truncate(TITLE_LIMIT)
    @failures = @podcast.fetch_failures.to_i
    mail to: owner.email, subject: "We can't read #{@title}'s feed"
  end

  def access_request
    @podcast = params[:podcast]
    @requester = params[:requester]
    owner = @podcast.owner_show&.user
    return if owner&.email.blank? || @requester.email.blank?

    @title = @podcast.title.to_s.squish.truncate(TITLE_LIMIT)
    @name = @requester.name.to_s.squish.truncate(80).presence || "Someone"
    mail to: owner.email, reply_to: @requester.email, subject: "#{@name} asked for access to #{@title} on #{APP_NAME}"
  end

  def feed_moved
    @show = params[:show]
    email = @show.user&.email
    return if email.blank?

    @title = @show.podcast.title.to_s.squish.truncate(TITLE_LIMIT)
    @to = params[:to].to_s.squish.truncate(URL_LIMIT)
    mail to: email, subject: FEED_MOVED_SUBJECT
  end
end
