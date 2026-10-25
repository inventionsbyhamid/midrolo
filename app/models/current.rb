# Per request (or job) state, reset by Rails after each one.
class Current < ActiveSupport::CurrentAttributes
  # Billing.mode when BILLING_MODE=live: the go live check runs a few queries, so it is worked out once (R110).
  attribute :live_billing_mode
end
