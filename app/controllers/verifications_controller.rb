# Proving a user owns a show (claiming it), which publishing its listing requires: a code emailed to the feed's owner
# address, or a token placed in the feed. Scoped to the user's own shows. Claims usually start from the podcast's page
# (ClaimsController), which tries the instant claim first and lands here otherwise.
class VerificationsController < ApplicationController
  layout "app"
  before_action :authenticate_user!
  before_action :set_show
  # Each feed check fetches the feed, so cap how fast anyone can press the buttons (codes have their own limits).
  rate_limit to: 10, within: 1.minute, only: %i[create update], by: -> { current_user.id }, name: "tries",
             store: RATE_LIMIT_STORE,
             with: -> { redirect_to new_show_verification_path(params[:show_id]), alert: "Too many tries. Wait a minute, then try again." }
  # Emailed codes, per show, on top of ShowVerification's resend and daily limits. set_show found the show, so however
  # its id is spelled ("01", "%31") it is the same show, and only its owner's requests count.
  throttle to: 5, within: 1.hour, only: :create, if: -> { params[:kind] == "email" }, by: -> { @show.id },
           name: "code_sends"
  # And per user across all their shows, so one account can't spend the day's mail on owner addresses (R143).
  throttle to: 10, within: 1.day, only: :create, if: -> { params[:kind] == "email" }, by: -> { current_user.id },
           name: "code_sends_per_user"

  VERIFIED = "You're verified. Set up your listing and publish it when it's ready.".freeze
  ALREADY_VERIFIED = "You've already verified this show, so there's nothing to send.".freeze
  NO_OWNER_EMAIL = "Your feed doesn't list an owner email, so we can't send a code. Verify with a feed token instead.".freeze
  NO_FEED = "We don't have an RSS feed for this show, so we can't look for a token. Verify by email instead.".freeze

  def new
    @current = ShowVerification.current_for(@show)
  end

  # A verified show never sends another code or issues a token.
  def create
    return redirect_to(edit_show_media_kit_path(@show), notice: ALREADY_VERIFIED, status: :see_other) if @show.verified?

    case params[:kind]
    when "email" then ShowVerification.request_code!(@show)
    when "feed_token" then ShowVerification.start_feed_token!(@show)
    else return redirect_to(new_show_verification_path(@show), alert: "Choose how you'd like to verify.", status: :see_other)
    end
    redirect_to show_verification_path(@show), status: :see_other
  rescue ShowVerification::Throttled => e
    redirect_to show_verification_path(@show), alert: throttled_message(e), status: :see_other
  rescue ShowVerification::Unavailable
    redirect_to new_show_verification_path(@show), alert: (params[:kind] == "email" ? NO_OWNER_EMAIL : NO_FEED), status: :see_other
  end

  def show
    @verification = ShowVerification.current_for(@show)
    redirect_to new_show_verification_path(@show) if @show.verified? || @verification.nil?
  end

  def update
    verification = ShowVerification.current_for(@show)
    return redirect_to(new_show_verification_path(@show), status: :see_other) if @show.verified? || verification.nil?

    if verification.email? ? verification.check_code(params[:code]) : verification.check_feed_token!
      @show.reload.sync_listing!
      redirect_to edit_show_media_kit_path(@show), notice: VERIFIED, status: :see_other
    else
      # A wrong code or a token not in the feed yet is said in the card, next to what to do (review PO-4, PO-5).
      if verification.failure.in?(%i[wrong_code not_found])
        flash[:verify_note] = failure_message(verification)
        redirect_to show_verification_path(@show), status: :see_other
      else
        redirect_to show_verification_path(@show), alert: failure_message(verification), status: :see_other
      end
    end
  rescue Show::AlreadyClaimed => e
    # The claim page offers to ask the owner for access.
    redirect_to new_podcast_claim_path(@show.podcast), alert: e.message, status: :see_other
  end

  private

  def set_show
    @show = current_user.shows.includes(:podcast).find_by!(public_id: params[:show_id])
  end

  # The address scope counts codes from every account to that inbox, so its copy doesn't say "you".
  def throttled_message(error)
    wait = error.reason == :resend ? helpers.pluralize(error.retry_in, "second") : helpers.distance_of_time_in_words(error.retry_in)
    case [ error.reason, error.scope ]
    in [ :resend, :show ] then "We just sent a code. You can request another in #{wait}."
    in [ :resend, :address ] then "A code just went to this address. You can request another in #{wait}."
    in [ :daily, :show ]
      "You've requested #{ShowVerification::SENDS_PER_DAY} codes today. You can request another in #{wait}, " \
        "or verify with a feed token instead."
    in [ :daily, :address ]
      "This address has had #{ShowVerification::SENDS_PER_DAY} codes today. You can request another in #{wait}, " \
        "or verify with a feed token instead."
    end
  end

  def failure_message(verification)
    case verification.failure
    when :wrong_code then "That code didn't match. You have #{helpers.pluralize(verification.attempts_left, 'try')} left."
    when :locked then ShowVerification::LOCKED_MESSAGE
    when :not_found
      "Not in your feed yet. Your host may not have updated it, so give it a few minutes and check again."
    when :unreadable then "We couldn't read your feed just now. Check that it's online, then try again in a few minutes."
    else verification.email? ? ShowVerification::EXPIRED_CODE_MESSAGE : "That token has expired. Get a new one below."
    end
  end
end
