# "Manage billing": opens the customer portal of the provider behind the user's subscription (spec §5.8), in any
# billing mode (R73). The redirect goes only to the URL the provider returns.
class BillingPortalsController < ApplicationController
  before_action :authenticate_user!
  before_action :refuse_while_masquerading, only: :create

  def create
    subscription = Billing.portal_subscription(current_user)
    provider = subscription && Billing::Provider.for(subscription.provider)
    return head :not_found unless provider

    redirect_to provider.portal_url(subscription, return_url: account_url), allow_other_host: true
  rescue Billing::Unavailable, Billing::MissingCredentials => e
    Rails.logger.error("[Billing] portal for subscription #{subscription.id} failed: #{e.message}")
    redirect_to account_path, alert: "We couldn't open billing just now. Please try again."
  end
end
