require "rails_helper"

RSpec.describe Billing::Providers::Dodo do
  subject(:dodo) { described_class.new(api_key: "test_key_not_real", environment: :test_mode, webhook_secret: secret) }

  let(:secret) { BillingHelpers::DODO_TEST_WEBHOOK_SECRET }
  let(:user) { create(:user, email: "ada@example.com", name: "Ada Lovelace") }

  around { |example| with_billing_env("DODO_PRODUCT_CREATOR_MONTHLY" => "pdt_test_creator_monthly") { example.run } }

  describe "#checkout_url" do
    let(:return_url) { "https://midrolo.test/billing/success" }

    def stub_checkout(status: 200, body: { session_id: "cks_test_1", checkout_url: "https://test.checkout.dodopayments.com/session/cks_test_1" })
      stub_request(:post, "https://test.dodopayments.com/checkouts")
        .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "opens a hosted checkout for the price key's product, with the user and price key in metadata" do
      stub = stub_checkout

      url = dodo.checkout_url(user: user, price_key: "creator_monthly", return_url: return_url)

      expect(url).to eq("https://test.checkout.dodopayments.com/session/cks_test_1")
      expect(stub.with { |request|
        body = JSON.parse(request.body)
        request.headers["Authorization"] == "Bearer test_key_not_real" &&
          body["product_cart"] == [ { "product_id" => "pdt_test_creator_monthly", "quantity" => 1 } ] &&
          body["metadata"] == { "user_id" => user.id.to_s, "price_key" => "creator_monthly" } &&
          body["customer"] == { "email" => "ada@example.com", "name" => "Ada Lovelace" } &&
          body["return_url"] == return_url
      }).to have_been_requested
    end

    it "talks to Dodo's live API only in live_mode" do
      stub = stub_request(:post, "https://live.dodopayments.com/checkouts")
        .to_return(status: 200, body: { session_id: "cks_1", checkout_url: "https://checkout.dodopayments.com/session/cks_1" }.to_json,
                   headers: { "Content-Type" => "application/json" })
      live = described_class.new(api_key: "live_key_not_real", environment: :live_mode, webhook_secret: secret)

      expect(live.checkout_url(user: user, price_key: "creator_monthly", return_url: return_url))
        .to eq("https://checkout.dodopayments.com/session/cks_1")
      expect(stub).to have_been_requested
    end

    it "raises MissingCredentials when the price key has no product id" do
      expect { dodo.checkout_url(user: user, price_key: "pro_monthly", return_url: return_url) }
        .to raise_error(Billing::MissingCredentials, /DODO_PRODUCT_PRO_MONTHLY/)
    end

    it "raises Unavailable when Dodo refuses or returns no checkout URL" do
      stub_checkout(status: 401, body: { message: "unauthorized" })
      expect { dodo.checkout_url(user: user, price_key: "creator_monthly", return_url: return_url) }
        .to raise_error(Billing::Unavailable)

      stub_checkout(body: { session_id: "cks_test_2", checkout_url: nil })
      expect { dodo.checkout_url(user: user, price_key: "creator_monthly", return_url: return_url) }
        .to raise_error(Billing::Unavailable, /no checkout URL/)
    end
  end

  describe "#portal_url" do
    let(:subscription) { create(:subscription, user: user, provider_customer_id: "cus_test_001") }

    it "opens a customer portal session for the subscription's customer" do
      stub = stub_request(:post, "https://test.dodopayments.com/customers/cus_test_001/customer-portal/session")
        .with(query: { return_url: "https://midrolo.test/account" })
        .to_return(status: 200, body: { link: "https://test.customer.dodopayments.com/session/cps_1" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      expect(dodo.portal_url(subscription, return_url: "https://midrolo.test/account"))
        .to eq("https://test.customer.dodopayments.com/session/cps_1")
      expect(stub).to have_been_requested
    end

    it "raises Unavailable when Dodo fails" do
      stub_request(:post, %r{/customers/cus_test_001/customer-portal/session}).to_return(status: 404, body: "{}")
      expect { dodo.portal_url(subscription) }.to raise_error(Billing::Unavailable)
    end
  end

  describe "#verify! (Standard Webhooks)" do
    let(:body) { dodo_webhook("subscription_active", user: user) }

    it "accepts a body signed with DODO_WEBHOOK_SECRET and returns its webhook-id" do
      expect(dodo.verify!(body, signed_webhook_headers(body, id: "msg_test_1"))).to eq("msg_test_1")
    end

    it "rejects a tampered body, another secret, or missing headers" do
      headers = signed_webhook_headers(body)
      expect { dodo.verify!(body.sub("creator_monthly", "pro_monthly"), headers) }.to raise_error(Billing::InvalidSignature)

      other = "whsec_#{Base64.strict_encode64('some-other-secret')}"
      expect { dodo.verify!(body, signed_webhook_headers(body, secret: other)) }.to raise_error(Billing::InvalidSignature)

      expect { dodo.verify!(body, headers.except("webhook-signature")) }.to raise_error(Billing::InvalidSignature)
      expect { dodo.verify!(body, {}) }.to raise_error(Billing::InvalidSignature)
    end

    it "rejects a timestamp more than 5 minutes off, so a captured webhook can't be replayed later" do
      stale = signed_webhook_headers(body, timestamp: 6.minutes.ago.to_i)
      future = signed_webhook_headers(body, timestamp: 6.minutes.from_now.to_i)

      expect { dodo.verify!(body, stale) }.to raise_error(Billing::InvalidSignature, /too old/)
      expect { dodo.verify!(body, future) }.to raise_error(Billing::InvalidSignature, /too new/)
      expect(dodo.verify!(body, signed_webhook_headers(body, timestamp: 4.minutes.ago.to_i))).to be_present
    end

    it "raises MissingCredentials without a webhook secret" do
      unconfigured = described_class.new(api_key: nil, environment: :test_mode, webhook_secret: nil)
      expect { unconfigured.verify!(body, signed_webhook_headers(body)) }
        .to raise_error(Billing::MissingCredentials, /DODO_WEBHOOK_SECRET/)
    end
  end

  describe "#parse" do
    def parse(fixture, **options) = dodo.parse(dodo_webhook(fixture, user: user, **options), id: "msg_1")

    it "normalizes subscription.active" do
      event = parse("subscription_active")

      expect(event).to have_attributes(
        id: "msg_1", provider: "dodo", type: :subscription_active, name: "subscription.active",
        customer_id: "cus_test_001", subscription_id: "sub_test_creator_001", price_key: "creator_monthly",
        user_id: user.id.to_s, period_start: Time.utc(2026, 10, 25, 12), period_end: Time.utc(2026, 11, 25, 12),
        cancel_at_period_end: false, occurred_at: Time.utc(2026, 10, 25, 12, 0, 5)
      )
      expect(event.raw).to include("type" => "subscription.active", "business_id" => "bus_test_midrolo")
    end

    it "maps Dodo's subscription events to ours" do
      expect(parse("subscription_renewed").type).to eq(:subscription_renewed)
      expect(parse("subscription_cancelled").type).to eq(:subscription_canceled)
      expect(parse("subscription_cancelled", type: "subscription.expired").type).to eq(:subscription_canceled)
      %w[subscription.failed subscription.on_hold subscription.past_due].each do |name|
        expect(parse("subscription_active", type: name).type).to eq(:payment_failed)
      end
    end

    it "maps subscription.updated by the status it reports, so a scheduled cancellation reaches us" do
      expect(parse("subscription_active", type: "subscription.updated", cancel_at_next_billing_date: true))
        .to have_attributes(type: :subscription_active, cancel_at_period_end: true)
      expect(parse("subscription_active", type: "subscription.updated", status: "cancelled").type).to eq(:subscription_canceled)
      expect(parse("subscription_active", type: "subscription.updated", status: "on_hold").type).to eq(:payment_failed)
      expect(parse("subscription_active", type: "subscription.updated", status: "pending").type).to be_nil
    end

    it "normalizes a one-time payment as one_time_paid, at the event's time" do
      event = parse("payment_succeeded_onetime")

      expect(event).to have_attributes(
        type: :one_time_paid, name: "payment.succeeded", customer_id: "cus_test_002", subscription_id: nil,
        price_key: "sprint", user_id: user.id.to_s, occurred_at: Time.utc(2026, 10, 25, 12, 0, 4)
      )
    end

    it "leaves a subscription's own payments to the subscription events" do
      expect(parse("payment_succeeded_onetime", subscription_id: "sub_test_creator_001").type).to be_nil
    end

    it "gives no type to an event it doesn't act on, keeping its name" do
      expect(parse("subscription_active", type: "dispute.opened")).to have_attributes(type: nil, name: "dispute.opened")
    end

    it "prefers the price key of the paid product to the metadata's" do
      with_billing_env("DODO_PRODUCT_PRO_MONTHLY" => "pdt_test_creator_monthly") do
        expect(parse("subscription_active").price_key).to eq("pro_monthly")
      end
      with_billing_env("DODO_PRODUCT_SPRINT" => "pdt_test_sprint") do
        expect(parse("payment_succeeded_onetime", metadata: {}).price_key).to eq("sprint")
      end
    end

    it "never raises on a payload of the wrong shape" do
      [ "[]", "{}", { type: "subscription.active", data: "nope" }.to_json,
        { type: "subscription.active", timestamp: "not a time", data: { customer: "x", metadata: [ 1 ] } }.to_json ].each do |raw|
        expect(dodo.parse(raw, id: "msg_2")).to be_a(Billing::Event)
      end
    end
  end
end
