# Billing specs: a clean billing ENV per example, synthetic Dodo webhooks from spec/fixtures/dodo, and real Standard
# Webhooks signatures over them (the same check production runs).
module BillingHelpers
  BILLING_ENV = %w[BILLING_MODE BILLING_PROVIDER DODO_API_KEY DODO_ENVIRONMENT DODO_WEBHOOK_SECRET DODO_PRODUCT_CREATOR_MONTHLY
                   DODO_PRODUCT_CREATOR_YEARLY DODO_PRODUCT_PRO_MONTHLY DODO_PRODUCT_PRO_YEARLY DODO_PRODUCT_SPRINT].freeze
  # A made-up signing secret in Dodo's whsec_ format; never a real one.
  DODO_TEST_WEBHOOK_SECRET = "whsec_#{Base64.strict_encode64('midrolo-spec-dodo-webhook-secret')}".freeze

  # Runs the block with only these billing variables set (every other BILLING_ENV one unset), then restores them.
  # The memoized provider is rebuilt on both sides.
  def with_billing_env(vars = {})
    saved = BILLING_ENV.index_with { |name| ENV[name] }
    BILLING_ENV.each { |name| ENV.delete(name) }
    vars.each { |name, value| ENV[name] = value }
    Billing.reset!
    yield
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    Billing.reset!
  end

  # A fixture's JSON body: data.metadata.user_id set to user's id, and the given data fields and top-level type or
  # timestamp replaced.
  def dodo_webhook(fixture, user: nil, type: nil, timestamp: nil, **data)
    payload = JSON.parse(Rails.root.join("spec/fixtures/dodo/#{fixture}.json").read)
    payload["type"] = type if type
    payload["timestamp"] = timestamp.utc.iso8601(6) if timestamp
    payload["data"]["metadata"]["user_id"] = user.id.to_s if user
    payload["data"].merge!(data.deep_stringify_keys)
    payload.to_json
  end

  # The Standard Webhooks headers for body, signed with secret at timestamp.
  def signed_webhook_headers(body, secret: DODO_TEST_WEBHOOK_SECRET, id: "msg_test_#{SecureRandom.hex(6)}",
                             timestamp: Time.current.to_i)
    { "webhook-id" => id, "webhook-timestamp" => timestamp.to_s,
      "webhook-signature" => StandardWebhooks::Webhook.new(secret).sign(id, timestamp, body),
      "CONTENT_TYPE" => "application/json" }
  end
end

RSpec.configure do |config|
  config.include BillingHelpers
end
