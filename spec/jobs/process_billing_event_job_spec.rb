require "rails_helper"

RSpec.describe ProcessBillingEventJob do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }

  around do |example|
    env = { "BILLING_MODE" => "test", "DODO_PRODUCT_CREATOR_MONTHLY" => "pdt_test_creator_monthly" }
    travel_to(Time.utc(2026, 10, 25, 12, 0, 10)) { with_billing_env(env) { example.run } }
  end

  def billing_event(fixture = "subscription_active", **options)
    BillingEvent.create!(provider: "dodo", event_id: "msg_#{SecureRandom.hex(4)}", event_type: "x",
                         payload: JSON.parse(dodo_webhook(fixture, user: user, **options)))
  end

  it "applies the event and marks it processed" do
    row = billing_event

    described_class.perform_now(row.id)

    expect(row.reload).to have_attributes(processed_at: Time.current, error_message: nil)
    expect(user.subscriptions.sole).to have_attributes(plan: "creator", status: "active")
  end

  it "does nothing for an event already processed" do
    row = billing_event
    row.update!(processed_at: 1.minute.ago)
    allow(Billing::Sync).to receive(:apply)

    described_class.perform_now(row.id)

    expect(Billing::Sync).not_to have_received(:apply)
    expect(row.reload.processed_at).to eq(1.minute.ago)
  end

  it "marks an event type it doesn't act on processed, changing nothing" do
    row = billing_event(type: "dispute.opened")

    described_class.perform_now(row.id)

    expect(row.reload).to have_attributes(processed_at: be_present, error_message: nil)
    expect(Subscription.count).to eq(0)
  end

  it "marks an event for no user processed with a note" do
    allow(Rails.logger).to receive(:error)
    row = billing_event
    row.payload["data"]["metadata"]["user_id"] = "999999"
    row.save!

    described_class.perform_now(row.id)

    expect(row.reload).to have_attributes(processed_at: be_present, error_message: a_string_matching(/No user/))
    expect(Subscription.count).to eq(0)
  end

  it "retries a cancellation that comes before its subscription, then gives up with a note" do
    allow(Rails.logger).to receive(:warn)
    row = billing_event("subscription_cancelled")

    perform_enqueued_jobs { described_class.perform_later(row.id) }

    expect(row.reload).to have_attributes(processed_at: be_present, error_message: a_string_matching(/sub_test_creator_001/))
    expect(Subscription.count).to eq(0)
  end

  it "applies a cancellation once its subscription has arrived" do
    cancel = billing_event("subscription_cancelled")
    described_class.perform_now(cancel.id) # raises inside, and retry_on schedules another try
    expect(cancel.reload.processed_at).to be_nil

    described_class.perform_now(billing_event.id)
    described_class.perform_now(cancel.id)

    expect(cancel.reload.processed_at).to be_present
    expect(user.subscriptions.sole.status).to eq("canceled")
  end

  it "settles an event from a provider this app doesn't have, rather than failing on every retry" do
    row = BillingEvent.create!(provider: "stripe", event_id: "evt_1", payload: { "type" => "x" })

    described_class.perform_now(row.id)

    expect(row.reload).to have_attributes(processed_at: be_present, error_message: 'No billing provider "stripe" here')
  end

  it "ignores an id that no longer exists" do
    expect { described_class.perform_now(0) }.not_to raise_error
  end
end
