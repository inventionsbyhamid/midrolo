module Billing
  module Providers
    # Dodo Payments (merchant of record), through the dodopayments gem: the one place the app uses it. The environment
    # is always passed, since the gem defaults to live: test_mode unless DODO_ENVIRONMENT=live_mode.
    # Webhooks need only DODO_WEBHOOK_SECRET; checkout and the portal need DODO_API_KEY.
    class Dodo
      include WebhookSignature

      NAME = "dodo".freeze
      # Dodo's event names => ours (R66). Anything else, payment.succeeded aside, is logged and changes nothing.
      EVENT_TYPES = {
        "subscription.active" => :subscription_active,
        "subscription.renewed" => :subscription_renewed,
        "subscription.cancelled" => :subscription_canceled,
        "subscription.expired" => :subscription_canceled,
        "subscription.failed" => :payment_failed,
        "subscription.on_hold" => :payment_failed,
        "subscription.past_due" => :payment_failed
      }.freeze
      # subscription.updated fires on any change (a cancellation scheduled in the portal, say), and plan_changed on an
      # upgrade or downgrade: we map both by the status they report. pending and paused change nothing.
      BY_STATUS = %w[subscription.updated subscription.plan_changed].freeze
      STATUS_TYPES = {
        "active" => :subscription_active, "cancelled" => :subscription_canceled, "expired" => :subscription_canceled,
        "failed" => :payment_failed, "on_hold" => :payment_failed, "past_due" => :payment_failed
      }.freeze
      # The buyer waits on checkout and the portal: fail fast instead of the gem's default minute.
      TIMEOUT = 15
      # What a stored webhook keeps (R77): ids, product, status, amounts and dates, and only our own metadata. Never the
      # customer's name, email, phone, address or card. #parse reads nothing else, so a stored payload parses as the
      # delivered one did.
      STORED_FIELDS = %w[payload_type subscription_id payment_id product_id status currency total_amount
                         recurring_pre_tax_amount created_at previous_billing_date next_billing_date cancelled_at
                         expires_at cancel_at_next_billing_date].freeze
      STORED_METADATA = %w[user_id price_key].freeze

      # Dodo's worst case taken from one payment (Billing::Margins), as its pricing pages state it.
      FEES = { rate: BigDecimal("0.06"), fixed_usd: BigDecimal("0.40") }.freeze

      # The registry contract (Billing::Provider).
      def self.configured? = ENV["DODO_API_KEY"].present?
      def self.environment = ENV["DODO_ENVIRONMENT"] == "live_mode" ? :live_mode : :test_mode
      def self.setup = "DODO_API_KEY"
      def self.live_setup = "DODO_API_KEY and DODO_ENVIRONMENT=live_mode"
      def self.fees = FEES

      attr_reader :webhook_secret

      def initialize(api_key: ENV["DODO_API_KEY"], environment: self.class.environment,
                     webhook_secret: ENV["DODO_WEBHOOK_SECRET"])
        @api_key = api_key
        @environment = environment
        @webhook_secret = webhook_secret
      end

      def name = NAME
      def test_mode? = @environment == :test_mode
      def webhook_secret_name = "DODO_WEBHOOK_SECRET"

      def checkout_url(user:, price_key:, return_url:)
        product_id = Billing.product_id(price_key, provider: NAME)
        raise MissingCredentials, "DODO_PRODUCT_#{price_key.to_s.upcase} is not set" unless product_id

        session = call_api("checkout") do
          client.checkout_sessions.create(
            product_cart: [ { product_id: product_id, quantity: 1 } ],
            customer: { email: user.email, name: user.name.presence }.compact,
            metadata: { user_id: user.id.to_s, price_key: price_key.to_s },
            return_url: return_url
          )
        end
        session.checkout_url.presence || raise(Unavailable, "Dodo returned no checkout URL")
      end

      def portal_url(subscription, return_url: nil)
        call_api("customer portal") do
          client.customers.customer_portal.create(subscription.provider_customer_id, **{ return_url: return_url }.compact)
        end.link
      end

      def parse(raw_body, id: nil)
        payload = object(JSON.parse(raw_body.to_s))
        data = object(payload["data"])
        metadata = object(data["metadata"])
        name = text(payload["type"]).to_s
        Event.new(
          id: id, provider: NAME, type: type_for(name, data), name: name,
          customer_id: text(object(data["customer"])["customer_id"]), subscription_id: text(data["subscription_id"]),
          payment_id: text(data["payment_id"]), price_key: price_key_for(data, metadata), user_id: text(metadata["user_id"]),
          period_start: time(data["previous_billing_date"]), period_end: time(data["next_billing_date"]),
          cancel_at_period_end: flag(data["cancel_at_next_billing_date"]),
          occurred_at: time(payload["timestamp"]), raw: stored(payload, data, metadata)
        )
      rescue JSON::ParserError
        Event.new(id: id, provider: NAME, type: nil, name: "")
      end

      private

      def client
        raise MissingCredentials, "DODO_API_KEY is not set" if @api_key.blank?

        @client ||= Dodopayments::Client.new(bearer_token: @api_key, environment: @environment, timeout: TIMEOUT)
      end

      def call_api(what)
        yield
      rescue Dodopayments::Errors::Error => e
        raise Unavailable, "Dodo #{what} failed: #{e.class}: #{e.message}"
      end

      # payment.succeeded is ours only for a one-time purchase: a subscription's payments come with its own events.
      def type_for(name, data)
        case name
        when *BY_STATUS then STATUS_TYPES[text(data["status"])]
        when "payment.succeeded" then :one_time_paid if text(data["subscription_id"]).nil?
        else EVENT_TYPES[name]
        end
      end

      # The paid product's price key (R75a). Our checkout's metadata counts only when the payload names no product at
      # all: a static payment link copies metadata_* query parameters into metadata, so another product of the business
      # could otherwise claim to be the Sprint. A product that isn't ours gives nil, and Sync notes it.
      def price_key_for(data, metadata)
        product_id = text(data["product_id"]) || text(object(Array(data["product_cart"]).first)["product_id"])
        product_id ? Billing.price_key_for_product(product_id, provider: NAME) : text(metadata["price_key"])
      end

      def stored(payload, data, metadata)
        kept = data.slice(*STORED_FIELDS)
        kept["customer"] = object(data["customer"]).slice("customer_id") if data.key?("customer")
        kept["metadata"] = metadata.slice(*STORED_METADATA) if data.key?("metadata")
        if data.key?("product_cart")
          kept["product_cart"] = Array(data["product_cart"]).map { |item| object(item).slice("product_id", "quantity") }
        end
        payload.slice("business_id", "type", "timestamp").merge("data" => kept)
      end

      # Total readers for a payload of any shape: a JSON object ({} otherwise), a string id, a boolean.
      def object(value) = value.is_a?(Hash) ? value : {}
      def text(value) = (value.to_s.presence if value.is_a?(String) || value.is_a?(Numeric))
      def flag(value) = (value if [ true, false ].include?(value))

      def time(value)
        Time.iso8601(value) if value.is_a?(String)
      rescue ArgumentError
        nil
      end
    end
  end
end
