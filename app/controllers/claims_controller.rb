# "Claim this show" from a podcast's public page (spec L4). new explains claiming (signing in first, and coming back
# here after); create makes or reuses the user's workspace and tries the instant claim (Claims::Start), then sends them
# to prove it another way; access asks the owner of an already claimed show for access (Claims::AccessRequest).
class ClaimsController < ApplicationController
  layout "app"
  # Sign in comes back here (build spec section 10).
  before_action :remember_claim, only: :new, unless: :user_signed_in?
  before_action :authenticate_user!
  before_action :set_podcast

  # Each claim reads the feed, so cap how fast anyone can press the button.
  throttle to: 10, within: 1.minute, only: :create, by: -> { current_user.id }, scope: "claims"
  # Each access request emails an owner; Claims::AccessRequest also sends one per user and show a week.
  throttle to: 5, within: 1.hour, only: :access, by: -> { current_user.id }, scope: "claim_access"

  CLAIMED = "%s is yours. Set up your listing below.".freeze
  # When requests waited for the claim (review PO-11): the best reason to look at the listing editor's inbox card.
  CLAIMED_WITH_REQUESTS = "%s is yours, and %s already asked about sponsoring it.".freeze
  ACCESS_SENT = "We asked the owner. If they know you, they'll reply to your email.".freeze
  ACCESS_ALREADY_SENT = "You asked the owner recently. Give them a few days to reply.".freeze
  # After "Check my feed again" (recheck=1) on the verification page.
  EMAIL_FOUND = "Your feed lists an owner email now, so we can email it a code.".freeze
  EMAIL_MISSING = "Your feed doesn't list an owner email yet. Hosts can take a while to update it, so try again in " \
                  "a few minutes, or add the line to your show description instead.".freeze

  def new
    @show = current_user.shows.find_by(podcast_id: @podcast.id)
    return redirect_to(edit_show_media_kit_path(@show)) if @show&.verified?

    @managed_elsewhere = @podcast.claimed?
    @asked_at = Claims::AccessRequest.asked_at(user: current_user, podcast: @podcast) if @managed_elsewhere
  end

  def create
    result = Claims::Start.call(user: current_user, podcast: @podcast)
    show = result.show
    case result.outcome
    when :verified then redirect_to edit_show_media_kit_path(show), notice: claimed_notice(show), status: :see_other
    when :owner then redirect_to edit_show_media_kit_path(show), status: :see_other
    else redirect_to next_step(show), status: :see_other, **recheck_message
    end
  rescue Show::AlreadyClaimed
    redirect_to new_podcast_claim_path(@podcast), status: :see_other
  end

  def access
    case Claims::AccessRequest.call(user: current_user, podcast: @podcast)
    when :sent then redirect_to new_podcast_claim_path(@podcast), notice: ACCESS_SENT, status: :see_other
    when :already_sent then redirect_to new_podcast_claim_path(@podcast), notice: ACCESS_ALREADY_SENT, status: :see_other
    else redirect_to new_podcast_claim_path(@podcast), status: :see_other
    end
  end

  private

  def set_podcast
    @podcast = Podcast.find_by_slug_or_redirect(params[:slug])
    raise ActiveRecord::RecordNotFound if @podcast.nil? || @podcast.removed?
  end

  def remember_claim
    store_location_for(:user, request.fullpath)
  end

  # Where proving it goes on: a code already sent, or a token while the feed has no owner email; else, with an owner
  # email, the choice of a code or a token; else the feed token straight away (the line to paste, with steps for their
  # host).
  def next_step(show)
    current = ShowVerification.current_for(show)
    return show_verification_path(show) if current&.pending? && (current.email? || @podcast.owner_email.blank?)
    return new_show_verification_path(show) if @podcast.owner_email.present? || @podcast.feed_url.blank?

    ShowVerification.start_feed_token!(show)
    show_verification_path(show)
  end

  def recheck_message
    return {} if params[:recheck].blank?

    @podcast.owner_email.present? ? { notice: EMAIL_FOUND } : { alert: EMAIL_MISSING }
  end

  def claimed_notice(show)
    asked = Conversation.where(podcast_id: show.podcast_id).open.count
    asked.positive? ? format(CLAIMED_WITH_REQUESTS, show.title, helpers.pluralize(asked, "brand")) : format(CLAIMED, show.title)
  end
end
