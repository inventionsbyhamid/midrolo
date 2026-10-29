module Billing
  # The payment provider behind checkout, the customer portal and webhooks (spec §9a). Adding one is one adapter class
  # in Billing::Providers, registered in ADAPTERS, plus its product ids in config/plans.yml (R145); nothing else in the
  # app names a vendor. The adapter interface:
  #   #name -> its ADAPTERS key: stored as Subscription#provider and BillingEvent#provider, and /webhooks/:name
  #   #test_mode? -> whether payments are test payments
  #   #checkout_url(user:, price_key:, return_url:) -> String: a hosted checkout whose metadata carries user_id and
  #     price_key. Raises MissingCredentials (no product id) or Unavailable.
  #   #portal_url(subscription, return_url: nil) -> String: the customer portal. Raises Unavailable.
  #   #verify!(raw_body, headers) -> the event id; raises InvalidSignature (Billing::WebhookSignature)
  #   #parse(raw_body, id:) -> Billing::Event. Never raises on a verified body, whatever its shape.
  # and, on the class, answered without raising:
  #   .configured? -> whether its keys are set
  #   .environment -> :test_mode or :live_mode
  #   .setup / .live_setup -> what to set, for messages ("DODO_API_KEY"; "DODO_API_KEY and DODO_ENVIRONMENT=live_mode")
  #   .fees -> { rate:, fixed_usd: }: the worst case taken from one payment (Billing::Margins)
  #
  # BILLING_PROVIDER names the provider. Unset, it's the first configured provider in REAL, else the Fake outside
  # production; production never runs the Fake.
  module Provider
    ADAPTERS = { "dodo" => "Billing::Providers::Dodo", "fake" => "Billing::Providers::Fake" }.freeze
    # The real providers, in the order an unset BILLING_PROVIDER tries them.
    REAL = %w[dodo].freeze
    # A merchant of record's worst case per payment, for margins when no provider is chosen.
    DEFAULT_FEES = { rate: BigDecimal("0.06"), fixed_usd: BigDecimal("0.40") }.freeze

    class << self
      def current
        @current ||= build
      end

      def reset!
        @current = nil
      end

      # The chosen provider's name, or nil when none is (production without one configured).
      def chosen_name
        ENV["BILLING_PROVIDER"].to_s.strip.downcase.presence ||
          REAL.find { |real| adapter(real).configured? } || ("fake" unless Rails.env.production?)
      end

      # The adapter for /webhooks/:name, or nil for a name we don't know (and for the Fake in production). A webhook
      # needs only the provider's signing secret, not its API key.
      def for(name)
        klass = adapter(name.to_s)
        klass.new if klass && !(klass == Providers::Fake && Rails.env.production?)
      end

      # Whether checkout would take test payments. Never raises.
      def test_mode? = mode == :test_mode

      # Whether checkout would take real payments. Never raises.
      def live? = mode == :live_mode

      def fees = chosen&.fees || DEFAULT_FEES

      # What live mode needs, in the chosen provider's words (every real provider's when none is chosen).
      def live_setup
        klass = chosen
        return klass.live_setup if klass && klass != Providers::Fake

        REAL.map { |real| adapter(real).live_setup }.join(", or ")
      end

      private

      def chosen = adapter(chosen_name)

      def adapter(name) = ADAPTERS[name.to_s]&.constantize

      def mode
        klass = chosen
        klass.environment if klass&.configured?
      end

      def build
        klass = chosen
        return klass.new if klass&.configured?

        if Rails.env.production?
          setup = klass ? klass.setup : REAL.map { |real| adapter(real).setup }.join(" or ")
          raise MissingCredentials, "Billing provider is not configured: set BILLING_PROVIDER and its keys (#{setup})"
        end
        Providers::Fake.new
      end
    end
  end
end
