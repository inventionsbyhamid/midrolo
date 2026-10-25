module Billing
  module Providers
    # The provider in development and test when DODO_API_KEY is unset; never in production. It calls nothing: checkout
    # and portal URLs are fixed paths on this site, and its webhooks are Billing::Event's own fields as JSON, signed with
    # WEBHOOK_SECRET and checked by the same Standard Webhooks code as Dodo's.
    class Fake
      include WebhookSignature

      NAME = "fake".freeze
      # Not a secret: it signs the Fake's webhooks only, and /webhooks/fake doesn't exist in production.
      WEBHOOK_SECRET = "whsec_#{Base64.strict_encode64('midrolo-fake-billing-webhooks')}".freeze

      def name = NAME
      def test_mode? = true
      def webhook_secret = WEBHOOK_SECRET
      def webhook_secret_name = "Billing::Providers::Fake::WEBHOOK_SECRET"

      def checkout_url(user:, price_key:, return_url:)
        "/fake_checkout?#{{ price_key: price_key, user_id: user.id }.to_query}"
      end

      def portal_url(subscription, return_url: nil)
        "/fake_portal?#{{ customer_id: subscription.provider_customer_id }.to_query}"
      end

      def parse(raw_body, id: nil)
        payload = JSON.parse(raw_body.to_s)
        payload = {} unless payload.is_a?(Hash)
        Event.new(
          id: id, provider: NAME, type: Event::TYPES.find { |type| type.to_s == payload["type"] }, name: payload["type"].to_s,
          customer_id: payload["customer_id"], subscription_id: payload["subscription_id"], price_key: payload["price_key"],
          user_id: payload["user_id"], period_start: time(payload["period_start"]), period_end: time(payload["period_end"]),
          cancel_at_period_end: payload["cancel_at_period_end"], occurred_at: time(payload["occurred_at"]), raw: payload
        )
      rescue JSON::ParserError
        Event.new(id: id, provider: NAME, type: nil, name: "")
      end

      private

      def time(value)
        Time.iso8601(value) if value.is_a?(String)
      rescue ArgumentError
        nil
      end
    end
  end
end
