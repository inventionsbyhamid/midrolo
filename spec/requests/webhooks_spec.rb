require "rails_helper"

RSpec.describe "Billing webhooks" do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }

  # Test mode, so payments may grant plans; the fixtures' product ids configured as ours.
  let(:env) do
    { "BILLING_MODE" => "test", "DODO_WEBHOOK_SECRET" => BillingHelpers::DODO_TEST_WEBHOOK_SECRET,
      "DODO_PRODUCT_CREATOR_MONTHLY" => "pdt_test_creator_monthly", "DODO_PRODUCT_SPRINT" => "pdt_test_sprint" }
  end

  around do |example|
    travel_to(Time.utc(2026, 10, 25, 12, 0, 10)) { with_billing_env(env) { example.run } }
  end

  def deliver(body, headers: signed_webhook_headers(body), provider: "dodo")
    perform_enqueued_jobs { post "/webhooks/#{provider}", params: body, headers: headers }
  end

  it "creates a Creator subscription from a valid signed subscription.active" do
    deliver(dodo_webhook("subscription_active", user: user))

    expect(response).to have_http_status(:ok)
    expect(user.subscriptions.sole).to have_attributes(
      provider: "dodo", provider_subscription_id: "sub_test_creator_001", provider_customer_id: "cus_test_001",
      plan: "creator", price_key: "creator_monthly", status: "active", current_period_end: Time.utc(2026, 11, 25, 12)
    )
    expect(BillingEvent.sole).to have_attributes(provider: "dodo", event_type: "subscription.active",
                                                 processed_at: be_present, error_message: nil)
    expect(Entitlements.for(user).key).to eq(:creator)
  end

  it "processes a replayed event id once: one BillingEvent and one update" do
    body = dodo_webhook("subscription_active", user: user)
    headers = signed_webhook_headers(body, id: "msg_replayed")
    deliver(body, headers: headers)
    allow(Billing::Sync).to receive(:apply).and_call_original

    expect { deliver(body, headers: headers) }.not_to change { Subscription.sole.updated_at }

    expect(response).to have_http_status(:ok)
    expect(BillingEvent.count).to eq(1)
    expect(Billing::Sync).not_to have_received(:apply)
  end

  it "ends active with the later period end when the renewal arrives before the activation" do
    deliver(dodo_webhook("subscription_renewed", user: user))
    deliver(dodo_webhook("subscription_active", user: user))

    expect(user.subscriptions.sole).to have_attributes(status: "active", current_period_end: Time.utc(2026, 12, 25, 12))
    expect(BillingEvent.count).to eq(2)
  end

  it "keeps a newer cancellation when a renewal arrives late" do
    deliver(dodo_webhook("subscription_active", user: user))
    deliver(dodo_webhook("subscription_cancelled", user: user))
    deliver(dodo_webhook("subscription_renewed", user: user))

    expect(user.subscriptions.sole).to have_attributes(status: "canceled", current_period_end: Time.utc(2026, 12, 25, 12))
  end

  it "turns a one-time Sprint payment into 30 days of Pro" do
    deliver(dodo_webhook("payment_succeeded_onetime", user: user))

    expect(user.subscriptions.sole).to have_attributes(plan: "sprint", status: "active",
                                                       current_period_end: Time.utc(2026, 11, 24, 12, 0, 4))
    expect(Entitlements.for(user).key).to eq(:sprint)
  end

  it "returns 400 for a bad signature and stores nothing" do
    body = dodo_webhook("subscription_active", user: user)
    forged = signed_webhook_headers(body, secret: "whsec_#{Base64.strict_encode64('attacker')}")

    deliver(body, headers: forged)

    expect(response).to have_http_status(:bad_request)
    expect(BillingEvent.count).to eq(0)
    expect(Subscription.count).to eq(0)
  end

  it "returns 400 for a missing signature or a stale timestamp" do
    body = dodo_webhook("subscription_active", user: user)

    deliver(body, headers: { "CONTENT_TYPE" => "application/json" })
    expect(response).to have_http_status(:bad_request)

    deliver(body, headers: signed_webhook_headers(body, timestamp: 10.minutes.ago.to_i))
    expect(response).to have_http_status(:bad_request)
    expect(BillingEvent.count).to eq(0)
  end

  it "returns 400, not 500, for a malformed signature header" do
    body = dodo_webhook("subscription_active", user: user)
    [ "v1", "v1,", "garbage" ].each do |signature|
      deliver(body, headers: signed_webhook_headers(body).merge("webhook-signature" => signature))
      expect(response).to have_http_status(:bad_request)
    end
    expect(BillingEvent.count).to eq(0)
  end

  it "stores the payload without the customer's name, email or address (R77)" do
    deliver(dodo_webhook("payment_succeeded_onetime", user: user))

    stored = BillingEvent.sole.payload
    expect(stored.to_json).not_to include("Test Sprinter", "sprinter@example.com", "2 Test Street", "Testville",
                                          '"billing"', "phone_number", "card_last_four")
    expect(stored.dig("data", "metadata")).to eq("user_id" => user.id.to_s, "price_key" => "sprint")
    expect(stored.dig("data", "payment_id")).to eq("pay_test_sprint_001")
  end

  it "keeps the customer's details out of the request log" do
    logged = nil
    log = ->(*, payload) { logged = payload[:params] if payload[:controller] == "WebhooksController" }
    ActiveSupport::Notifications.subscribed(log, "start_processing.action_controller") do
      deliver(dodo_webhook("payment_succeeded_onetime", user: user))
    end

    expect(logged.to_s).to include("pay_test_sprint_001")
    expect(logged.to_s).not_to include("Test Sprinter", "sprinter@example.com", "2 Test Street", "Testville", "4242")
  end

  it "grants nothing for another product's payment, even with sprint in its metadata (R75a)" do
    allow(Rails.logger).to receive(:error)
    deliver(dodo_webhook("payment_succeeded_onetime", user: user,
                                                      product_cart: [ { product_id: "pdt_someone_elses_ebook", quantity: 1 } ]))

    expect(Subscription.count).to eq(0)
    expect(BillingEvent.sole).to have_attributes(processed_at: be_present, error_message: a_string_matching(/not the sprint/))
  end

  it "grants nothing on the waitlist to a test payment made out to a regular user, but grants a judge (R75b)" do
    allow(Rails.logger).to receive(:error)
    with_billing_env(env.except("BILLING_MODE")) do
      deliver(dodo_webhook("payment_succeeded_onetime", user: user))
      expect(Subscription.count).to eq(0)
      expect(BillingEvent.sole.error_message).to match(/No plan granted/)

      judge = create(:user, judge: true)
      deliver(dodo_webhook("payment_succeeded_onetime", user: judge, payment_id: "pay_test_sprint_002"))
      expect(judge.subscriptions.sole.plan).to eq("sprint")
    end
  end

  it "returns 404 for a provider it doesn't know" do
    body = dodo_webhook("subscription_active", user: user)
    deliver(body, provider: "stripe")
    expect(response).to have_http_status(:not_found)
  end

  it "stores an unknown event type and marks it processed without changing anything (never a 500)" do
    deliver(dodo_webhook("subscription_active", user: user, type: "dispute.opened"))

    expect(response).to have_http_status(:ok)
    expect(BillingEvent.sole).to have_attributes(event_type: "dispute.opened", processed_at: be_present)
    expect(Subscription.count).to eq(0)
  end

  it "returns 503 and logs when DODO_WEBHOOK_SECRET isn't set, so Dodo retries once it is" do
    allow(Rails.logger).to receive(:error)
    body = dodo_webhook("subscription_active", user: user)

    with_billing_env { deliver(body) }

    expect(response).to have_http_status(:service_unavailable)
    expect(Rails.logger).to have_received(:error).with(/DODO_WEBHOOK_SECRET/)
  end

  it "takes webhooks with forgery protection on: CSRF is skipped for them only" do
    ActionController::Base.allow_forgery_protection = true
    deliver(dodo_webhook("subscription_active", user: user))

    expect(response).to have_http_status(:ok)
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  it "verifies the Fake provider's webhooks with the same Standard Webhooks check" do
    body = { type: "subscription_active", subscription_id: "fake_sub_1", customer_id: "fake_cus_1", price_key: "pro_monthly",
             user_id: user.id, period_start: "2026-10-25T12:00:00Z", period_end: "2026-11-25T12:00:00Z",
             occurred_at: "2026-10-25T12:00:01Z" }.to_json

    deliver(body, provider: "fake")
    expect(response).to have_http_status(:bad_request)

    deliver(body, provider: "fake", headers: signed_webhook_headers(body, secret: Billing::Providers::Fake::WEBHOOK_SECRET))
    expect(response).to have_http_status(:ok)
    expect(user.subscriptions.sole).to have_attributes(provider: "fake", plan: "pro", status: "active")
  end
end
