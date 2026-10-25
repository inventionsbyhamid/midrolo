# "Manage billing": opens the provider's customer portal for the user's subscription (spec §5.8), where checkout is
# open to them (Billing.portal_subscription). The redirect goes only to the URL the provider returns.
class BillingPortalsController < ApplicationController
  before_action :authenticate_user!

  def create
    subscription = Billing.portal_subscription(current_user)
    return head :not_found unless subscription

    redirect_to Billing::Provider.current.portal_url(subscription, return_url: account_url), allow_other_host: true
  rescue Billing::Unavailable => e
    Rails.logger.error("[Billing] portal for subscription #{subscription.id} failed: #{e.message}")
    redirect_to account_path, alert: "We couldn't open billing just now. Please try again."
  end
end
