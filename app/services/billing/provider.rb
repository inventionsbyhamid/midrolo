module Billing
  # The payment provider behind checkout, the customer portal and webhooks (spec §9a). Adapter interface:
  #   #name -> "dodo" | "fake": stored as Subscription#provider and BillingEvent#provider, and /webhooks/:name
  #   #test_mode? -> whether payments are test payments
  #   #checkout_url(user:, price_key:, return_url:) -> String: a hosted checkout whose metadata carries user_id and
  #     price_key. Raises MissingCredentials (no product id) or Unavailable.
  #   #portal_url(subscription, return_url: nil) -> String: the customer portal. Raises Unavailable.
  #   #verify!(raw_body, headers) -> the event id; raises InvalidSignature (Billing::WebhookSignature)
  #   #parse(raw_body, id:) -> Billing::Event. Never raises on a verified body, whatever its shape.
  module Provider
    class << self
      # Dodo when DODO_API_KEY is set; otherwise the Fake, outside production only.
      def current
        @current ||= build
      end

      def reset!
        @current = nil
      end

      # The adapter for /webhooks/:name, or nil for a name we don't know (and for the Fake in production). Dodo's
      # webhooks need only DODO_WEBHOOK_SECRET, not the API key.
      def for(name)
        case name.to_s
        when Providers::Dodo::NAME then Providers::Dodo.new
        when Providers::Fake::NAME then Providers::Fake.new unless Rails.env.production?
        end
      end

      # Whether checkout would take test payments: Dodo in test_mode, or the Fake outside production. Never raises.
      def test_mode?
        dodo_key? ? Providers::Dodo.environment == :test_mode : !Rails.env.production?
      end

      # Whether checkout would take real payments: Dodo with DODO_ENVIRONMENT=live_mode.
      def live?
        dodo_key? && Providers::Dodo.environment == :live_mode
      end

      private

      def dodo_key? = ENV["DODO_API_KEY"].present?

      def build
        return Providers::Dodo.new if dodo_key?
        raise MissingCredentials, "Billing provider is not configured: set DODO_API_KEY" if Rails.env.production?

        Providers::Fake.new
      end
    end
  end
end
