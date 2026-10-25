module Billing
  module Providers
    # The provider in development and test when DODO_API_KEY is unset; never in production. It calls nothing: checkout
    # and portal URLs are pages on this site (FakeBillingController, development and test only), and its webhooks are
    # Billing::Event's own fields as JSON, signed with WEBHOOK_SECRET and checked by the same Standard Webhooks code as
    # Dodo's.
    class Fake
      include WebhookSignature

      NAME = "fake".freeze
      # Not a secret: it signs the Fake's webhooks only, and /webhooks/fake doesn't exist in production.
      WEBHOOK_SECRET = "whsec_#{Base64.strict_encode64('midrolo-fake-billing-webhooks')}".freeze
      PERIODS = { monthly: 1.month, yearly: 1.year }.freeze

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
          customer_id: payload["customer_id"], subscription_id: payload["subscription_id"], payment_id: payload["payment_id"],
          price_key: payload["price_key"], user_id: payload["user_id"], period_start: time(payload["period_start"]),
          period_end: time(payload["period_end"]), cancel_at_period_end: payload["cancel_at_period_end"],
          occurred_at: time(payload["occurred_at"]), raw: payload
        )
      rescue JSON::ParserError
        Event.new(id: id, provider: NAME, type: nil, name: "")
      end

      # The webhook body a completed test checkout sends (the development checkout page): a new subscription for a
      # monthly or yearly price, a one-time payment for the sprint.
      def test_payment(user:, price:)
        now = Time.current
        fields = { customer_id: "fake_cus_#{user.id}", price_key: price.key, user_id: user.id, occurred_at: now.iso8601 }
        fields.merge!(
          if price.interval == :once
            { type: "one_time_paid", payment_id: "fake_pay_#{SecureRandom.hex(8)}" }
          else
            { type: "subscription_active", subscription_id: "fake_sub_#{SecureRandom.hex(8)}", period_start: now.iso8601,
              period_end: (now + PERIODS.fetch(price.interval)).iso8601, cancel_at_period_end: false }
          end
        )
        fields.to_json
      end

      # Standard Webhooks headers for body, signed with WEBHOOK_SECRET now.
      def signed_headers(body, id: "msg_fake_#{SecureRandom.hex(8)}")
        timestamp = Time.current.to_i
        { "webhook-id" => id, "webhook-timestamp" => timestamp.to_s,
          "webhook-signature" => StandardWebhooks::Webhook.new(WEBHOOK_SECRET).sign(id, timestamp, body) }
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
