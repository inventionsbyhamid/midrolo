# The paid plans' waitlist (spec §11): paid buttons in waitlist mode post here. A signed-in user joins with their
# account's email; a visitor gives one. Joining again is a friendly no-op with the same confirmation, which names the
# plan. Open in every billing mode, and limited per IP. The paused-runs notify-me box (shared/_runs_paused) posts here
# too, with Billing::NOTIFY_KEY: only signed in, so the notify list holds account emails, never one a visitor typed.
class WaitlistEntriesController < ApplicationController
  CONFIRMATION = "You're on the %{plan} waitlist. We'll email you when paid plans open.".freeze
  NOTIFY_CONFIRMATION = "Thanks. We'll email you when new reports are back.".freeze

  rate_limit to: 10, within: 1.hour, only: :create,
             with: -> { redirect_back_or_to pricing_path, alert: "Too many tries. Please try again later." }
  before_action :authenticate_user!, if: -> { params[:price_key].to_s == Billing::NOTIFY_KEY }

  def create
    email = user_signed_in? ? current_user.email : params[:email]
    entry = WaitlistEntry.join(email: email.to_s, price_key: params[:price_key].to_s, user: current_user)

    if entry.persisted?
      redirect_back_or_to pricing_path, notice: confirmation(entry)
    else
      redirect_back_or_to pricing_path, alert: entry.errors.first.message
    end
  end

  private

  def confirmation(entry)
    return NOTIFY_CONFIRMATION if entry.price_key == Billing::NOTIFY_KEY

    format(CONFIRMATION, plan: Entitlements.limits(Billing.plan_for(entry.price_key).to_sym)[:name])
  end
end
