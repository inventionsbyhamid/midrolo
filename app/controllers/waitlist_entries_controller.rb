# The founding-member waitlist (spec §11): paid buttons in waitlist mode post here. A signed-in user joins with their
# account's email; a visitor gives one. Joining again is a friendly no-op with the same confirmation. Open in every
# billing mode, and limited per IP. The paused-runs notify-me box (shared/_runs_paused) posts here too, with
# Billing::NOTIFY_KEY: only signed in, so the notify list holds account emails, never one a visitor typed.
class WaitlistEntriesController < ApplicationController
  CONFIRMATION = "You're on the founding-member list — we'll email you when paid plans open.".freeze
  NOTIFY_CONFIRMATION = "Thanks — we'll email you when new reports are back.".freeze

  rate_limit to: 10, within: 1.hour, only: :create,
             with: -> { redirect_back_or_to pricing_path, alert: "Too many tries. Please try again later." }
  before_action :authenticate_user!, if: -> { params[:price_key].to_s == Billing::NOTIFY_KEY }

  def create
    email = user_signed_in? ? current_user.email : params[:email]
    entry = WaitlistEntry.join(email: email.to_s, price_key: params[:price_key].to_s, user: current_user)

    if entry.persisted?
      redirect_back_or_to pricing_path, notice: entry.price_key == Billing::NOTIFY_KEY ? NOTIFY_CONFIRMATION : CONFIRMATION
    else
      redirect_back_or_to pricing_path, alert: entry.errors.first.message
    end
  end
end
