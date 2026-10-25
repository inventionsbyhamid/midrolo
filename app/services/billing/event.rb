module Billing
  # One provider webhook, normalized by its adapter's #parse (spec §9a). Billing::Sync reads only this, never raw.
  #   id               the provider's event id (for Dodo, the signed webhook-id header)
  #   type             one of TYPES, or nil for an event we don't act on
  #   name             the provider's own event name ("subscription.active"), kept for the BillingEvent log
  #   customer_id, subscription_id   the provider's ids (no subscription id for a one-time payment)
  #   payment_id                     a one-time payment's id, so a payment delivered twice applies once
  #   price_key, user_id             from the paid product, or our checkout's metadata; trusted only after #verify!
  #   period_start, period_end       the subscription's current billing period
  #   cancel_at_period_end           true when it won't renew; nil when the event doesn't say
  #   occurred_at                    when the provider says the event happened: ordering, and a sprint's paid time
  #   raw                            the payload to store in the BillingEvent log, without personal details
  class Event < Data.define(:id, :provider, :type, :name, :customer_id, :subscription_id, :payment_id, :price_key,
                            :user_id, :period_start, :period_end, :cancel_at_period_end, :occurred_at, :raw)
    TYPES = %i[subscription_active subscription_renewed subscription_canceled payment_failed one_time_paid].freeze

    def initialize(provider:, type:, name:, id: nil, customer_id: nil, subscription_id: nil, payment_id: nil,
                   price_key: nil, user_id: nil, period_start: nil, period_end: nil, cancel_at_period_end: nil,
                   occurred_at: nil, raw: {})
      raise ArgumentError, "unknown billing event type #{type.inspect}" unless type.nil? || TYPES.include?(type)

      super
    end
  end
end
