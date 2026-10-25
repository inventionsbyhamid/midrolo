require "rails_helper"

RSpec.describe Billing::Providers::Fake do
  subject(:fake) { described_class.new }

  let(:user) { create(:user) }

  it "returns deterministic checkout and portal URLs on this site" do
    expect(fake.checkout_url(user: user, price_key: "pro_monthly", return_url: "https://midrolo.test/billing/success"))
      .to eq("/fake_checkout?price_key=pro_monthly&user_id=#{user.id}")

    subscription = create(:subscription, user: user, provider: "fake", provider_customer_id: "fake_cus_1")
    expect(fake.portal_url(subscription)).to eq("/fake_portal?customer_id=fake_cus_1")
  end

  it "is always in test mode" do
    expect(fake).to be_test_mode
    expect(fake.name).to eq("fake")
  end

  describe "webhooks" do
    let(:body) do
      { type: "subscription_active", subscription_id: "fake_sub_1", customer_id: "fake_cus_1", price_key: "pro_monthly",
        user_id: user.id, period_start: "2026-10-25T12:00:00Z", period_end: "2026-11-25T12:00:00Z",
        cancel_at_period_end: false, occurred_at: "2026-10-25T12:00:01Z" }.to_json
    end

    it "verifies Standard Webhooks signatures made with its own test secret" do
      headers = signed_webhook_headers(body, secret: described_class::WEBHOOK_SECRET, id: "msg_fake_1")

      expect(fake.verify!(body, headers)).to eq("msg_fake_1")
      expect { fake.verify!(body, signed_webhook_headers(body)) }.to raise_error(Billing::InvalidSignature)
    end

    it "parses its payload, which is a Billing::Event's own fields" do
      expect(fake.parse(body, id: "msg_fake_1")).to have_attributes(
        id: "msg_fake_1", provider: "fake", type: :subscription_active, name: "subscription_active",
        subscription_id: "fake_sub_1", customer_id: "fake_cus_1", price_key: "pro_monthly", user_id: user.id,
        period_start: Time.utc(2026, 10, 25, 12), period_end: Time.utc(2026, 11, 25, 12), cancel_at_period_end: false,
        occurred_at: Time.utc(2026, 10, 25, 12, 0, 1)
      )
    end

    it "gives no type to anything else" do
      expect(fake.parse({ type: "something_else" }.to_json, id: "msg_2").type).to be_nil
      expect(fake.parse("[]", id: "msg_3").type).to be_nil
    end
  end
end
