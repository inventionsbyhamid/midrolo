# Starts a hosted checkout for one price key (spec §5.8, R66). Checkout exists in the test and live billing modes;
# on the waitlist it is a 404, except for judges and admins against a provider in test mode. The redirect goes only
# to the URL the provider returns, never to anything from params.
class CheckoutsController < ApplicationController
  THANKS = "Thanks — your plan updates in a few seconds.".freeze
  NOT_CHARGED = "Checkout didn't go through, so nothing was charged.".freeze
  # The statuses the provider's return URL reports for a checkout that took no payment.
  UNPAID_STATUSES = %w[failed expired].freeze

  before_action :not_found_unless_checkout_open, only: :create
  before_action :authenticate_user!

  def create
    price = Billing.price(params[:price_key])
    return redirect_to(pricing_path, alert: "That plan isn't available.") unless price

    url = Billing::Provider.current.checkout_url(user: current_user, price_key: price.key, return_url: billing_success_url)
    redirect_to url, allow_other_host: true
  rescue Billing::Unavailable, Billing::MissingCredentials => e
    Rails.logger.error("[Billing] checkout for #{price&.key} failed: #{e.message}")
    redirect_to pricing_path, alert: "We couldn't start checkout. Please try again."
  end

  # Where the provider sends the buyer back. The webhook changes the plan, maybe a moment later; the status parameter
  # is only the provider's hint about what happened.
  def success
    if UNPAID_STATUSES.include?(params[:status].to_s)
      redirect_to account_path, alert: NOT_CHARGED
    else
      redirect_to account_path, notice: THANKS
    end
  end

  private

  def not_found_unless_checkout_open
    head :not_found if Billing.mode == :waitlist && !Billing.checkout_open?(current_user)
  end
end
