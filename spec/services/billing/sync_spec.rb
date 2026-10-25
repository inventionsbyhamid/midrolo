require "rails_helper"

RSpec.describe Billing::Sync do
  let(:user) { create(:user) }
  let(:t0) { Time.utc(2026, 10, 25, 12) }

  # Test mode: checkout is open to every user, so payments may grant plans (R75b has its own examples below).
  around do |example|
    travel_to(Time.utc(2026, 10, 25, 12, 0, 10)) { with_billing_env("BILLING_MODE" => "test") { example.run } }
  end

  def event(type, **attributes)
    Billing::Event.new(provider: "dodo", type: type, name: type.to_s, subscription_id: "sub_1", customer_id: "cus_1",
                       price_key: "creator_monthly", user_id: user.id.to_s, period_start: t0, period_end: t0 + 1.month,
                       cancel_at_period_end: false, occurred_at: t0, **attributes)
  end

  def subscription = Subscription.find_by!(provider: "dodo", provider_subscription_id: "sub_1")

  describe "subscription events" do
    it "creates the subscription from its start, with the plan from the price key" do
      expect(described_class.apply(event(:subscription_active))).to be_nil

      expect(subscription).to have_attributes(
        user: user, plan: "creator", price_key: "creator_monthly", status: "active", provider_customer_id: "cus_1",
        current_period_start: t0, current_period_end: t0 + 1.month, cancel_at_period_end: false, last_event_at: t0
      )
    end

    it "takes the plan of any price key in plans.yml" do
      described_class.apply(event(:subscription_active, price_key: "pro_yearly", period_end: t0 + 1.year))
      expect(subscription).to have_attributes(plan: "pro", price_key: "pro_yearly")
    end

    it "updates the subscription it already has, found by provider and subscription id before any user" do
      existing = create(:subscription, user: user, provider: "dodo", provider_subscription_id: "sub_1", plan: "creator",
                                       current_period_end: t0 + 1.month, last_event_at: t0)
      described_class.apply(event(:subscription_renewed, user_id: nil, period_start: t0 + 1.month,
                                                         period_end: t0 + 2.months, occurred_at: t0 + 1.month))

      expect(existing.reload).to have_attributes(current_period_start: t0 + 1.month, current_period_end: t0 + 2.months)
      expect(Subscription.count).to eq(1)
    end

    it "ends active with the later period end when the renewal arrives before the activation (Review Focus #5)" do
      described_class.apply(event(:subscription_renewed, period_start: t0 + 1.month, period_end: t0 + 2.months,
                                                         occurred_at: t0 + 1.month))
      described_class.apply(event(:subscription_active))

      expect(subscription).to have_attributes(status: "active", current_period_start: t0 + 1.month,
                                              current_period_end: t0 + 2.months, last_event_at: t0 + 1.month)
    end

    it "never lets a late renewal override a newer cancellation, but still keeps the latest period end" do
      described_class.apply(event(:subscription_active))
      described_class.apply(event(:subscription_canceled, occurred_at: t0 + 40.days))
      described_class.apply(event(:subscription_renewed, period_start: t0 + 1.month, period_end: t0 + 2.months,
                                                         occurred_at: t0 + 1.month))

      expect(subscription).to have_attributes(status: "canceled", current_period_end: t0 + 2.months,
                                              last_event_at: t0 + 40.days)
    end

    it "marks a failed payment past due, and a newer renewal active again" do
      described_class.apply(event(:subscription_active))
      described_class.apply(event(:payment_failed, occurred_at: t0 + 1.month))
      expect(subscription.status).to eq("past_due")

      described_class.apply(event(:subscription_renewed, period_end: t0 + 2.months, occurred_at: t0 + 1.month + 2.days))
      expect(subscription).to have_attributes(status: "active", current_period_end: t0 + 2.months)
    end

    it "never extends the period on a failed, on-hold, cancelled or expired event (R76)" do
      described_class.apply(event(:subscription_active))
      described_class.apply(event(:payment_failed, period_start: t0 + 1.month, period_end: t0 + 2.months,
                                                   occurred_at: t0 + 1.month))
      described_class.apply(event(:subscription_canceled, period_start: t0 + 1.month, period_end: t0 + 2.months,
                                                          occurred_at: t0 + 1.month + 1.day))

      expect(subscription).to have_attributes(status: "canceled", current_period_start: t0, current_period_end: t0 + 1.month)
    end

    it "only moves the period end forward" do
      described_class.apply(event(:subscription_active, period_end: t0 + 2.months))
      described_class.apply(event(:subscription_renewed, period_end: t0 + 1.month, occurred_at: t0 + 1.day))

      expect(subscription.current_period_end).to eq(t0 + 2.months)
    end

    it "records a scheduled cancellation from a newer event" do
      described_class.apply(event(:subscription_active))
      described_class.apply(event(:subscription_active, cancel_at_period_end: true, occurred_at: t0 + 1.day))

      expect(subscription).to have_attributes(status: "active", cancel_at_period_end: true)
    end

    it "waits for the start event before a cancellation or failed payment it can't place yet" do
      expect { described_class.apply(event(:subscription_canceled)) }.to raise_error(described_class::UnknownSubscription)
      expect { described_class.apply(event(:payment_failed)) }.to raise_error(described_class::UnknownSubscription)
      expect(Subscription.count).to eq(0)
    end

    it "notes and logs an event for no user it can find, changing nothing" do
      allow(Rails.logger).to receive(:error)

      note = described_class.apply(event(:subscription_active, user_id: "999999"))

      expect(note).to match(/No user/)
      expect(Subscription.count).to eq(0)
      expect(Rails.logger).to have_received(:error).with(/No user/)
    end

    it "notes a price key plans.yml doesn't have" do
      expect(described_class.apply(event(:subscription_active, price_key: "enterprise"))).to match(/price key/)
      expect(described_class.apply(event(:subscription_active, price_key: "sprint"))).to match(/price key/)
      expect(Subscription.count).to eq(0)
    end

    it "notes an event with no subscription id" do
      expect(described_class.apply(event(:subscription_active, subscription_id: nil))).to match(/subscription id/)
    end
  end

  describe "one-time payments (the Sponsor Sprint)" do
    def paid(at: t0, **attributes)
      event(:one_time_paid, subscription_id: nil, customer_id: "cus_2", price_key: "sprint", occurred_at: at, **attributes)
    end

    def sprints = user.subscriptions.where(plan: "sprint").order(:id)

    it "creates a sprint that ends duration_days (plans.yml) after the payment" do
      described_class.apply(paid)

      expect(sprints.sole).to have_attributes(
        provider: "dodo", provider_customer_id: "cus_2", provider_subscription_id: nil, price_key: "sprint",
        status: "active", current_period_start: t0, current_period_end: t0 + 30.days
      )
      expect(Entitlements.for(user).key).to eq(:sprint)
    end

    it "reads the length from plans.yml" do
      allow(Entitlements).to receive(:limits).and_call_original
      allow(Entitlements).to receive(:limits).with(:sprint).and_return(duration_days: 14)

      described_class.apply(paid)
      expect(sprints.sole.current_period_end).to eq(t0 + 14.days)
    end

    it "extends a running sprint from its end when paid again" do
      described_class.apply(paid)
      described_class.apply(paid(at: t0 + 10.days))

      expect(sprints.sole.current_period_end).to eq(t0 + 60.days)
    end

    it "starts a new sprint once the last one has ended" do
      described_class.apply(paid(at: t0 - 40.days))
      described_class.apply(paid)

      expect(sprints.map(&:current_period_end)).to eq([ t0 - 10.days, t0 + 30.days ])
    end

    it "applies a payment once, even delivered again under another webhook id" do
      described_class.apply(paid(payment_id: "pay_1"))
      allow(Rails.logger).to receive(:error)

      expect(described_class.apply(paid(payment_id: "pay_1", id: "msg_again"))).to match(/applied already/)
      described_class.apply(paid(at: t0 + 1.day, payment_id: "pay_2"))

      expect(sprints.sole).to have_attributes(current_period_end: t0 + 60.days, payment_ids: %w[pay_1 pay_2])
    end

    it "notes a one-time payment that isn't the sprint, or has no user" do
      allow(Rails.logger).to receive(:error)
      expect(described_class.apply(paid(price_key: "creator_monthly"))).to match(/not the sprint/)
      expect(described_class.apply(paid(user_id: nil))).to match(/No user/)
      expect(Subscription.count).to eq(0)
    end
  end

  describe "who a payment may grant a plan to (R75b)" do
    let(:sprint_payment) do
      event(:one_time_paid, subscription_id: nil, price_key: "sprint", payment_id: "pay_1")
    end

    before { allow(Rails.logger).to receive(:error) }

    it "grants nothing to a regular user on the waitlist, where a test-mode payment link could name anyone" do
      with_billing_env do
        expect(described_class.apply(event(:subscription_active))).to match(/No plan granted/)
        expect(described_class.apply(sprint_payment)).to match(/No plan granted/)
      end
      expect(Subscription.count).to eq(0)
    end

    it "grants a judge or an admin on the waitlist their test checkout" do
      user.update!(judge: true)
      with_billing_env { described_class.apply(event(:subscription_active)) }
      expect(subscription.plan).to eq("creator")

      admin = create(:user, admin: true)
      with_billing_env { described_class.apply(sprint_payment.with(user_id: admin.id.to_s)) }
      expect(admin.subscriptions.sole.plan).to eq("sprint")
    end

    it "grants anyone when the provider takes live payments, whatever the mode" do
      with_billing_env("DODO_API_KEY" => "live_key_not_real", "DODO_ENVIRONMENT" => "live_mode") do
        described_class.apply(event(:subscription_active))
      end
      expect(subscription.status).to eq("active")
    end

    it "never extends a regular user's subscription on the waitlist either" do
      described_class.apply(event(:subscription_active))
      with_billing_env do
        described_class.apply(event(:subscription_renewed, period_end: t0 + 2.months, occurred_at: t0 + 1.month))
      end

      expect(subscription).to have_attributes(current_period_end: t0 + 1.month, status: "active", plan: "creator")
    end

    it "keeps what grants nothing from a refused event, such as a cancellation at period end, after a mode switch" do
      described_class.apply(event(:subscription_active))

      note = with_billing_env do
        described_class.apply(event(:subscription_active, price_key: "pro_monthly", cancel_at_period_end: true,
                                                          customer_id: "cus_2", period_end: t0 + 2.months,
                                                          occurred_at: t0 + 1.day))
      end

      expect(note).to match(/No plan granted/)
      expect(subscription).to have_attributes(cancel_at_period_end: true, provider_customer_id: "cus_2",
                                              last_event_at: t0 + 1.day, plan: "creator", status: "active",
                                              current_period_end: t0 + 1.month)
    end

    it "keeps a refused event's fields only when it is the newest" do
      described_class.apply(event(:subscription_active, cancel_at_period_end: true, occurred_at: t0 + 2.days))

      with_billing_env { described_class.apply(event(:subscription_active, occurred_at: t0 + 1.day)) }

      expect(subscription).to have_attributes(cancel_at_period_end: true, last_event_at: t0 + 2.days)
    end

    it "lets a refused event reactivate nothing" do
      described_class.apply(event(:subscription_active))
      described_class.apply(event(:subscription_canceled, occurred_at: t0 + 1.day))

      with_billing_env { described_class.apply(event(:subscription_active, occurred_at: t0 + 2.days)) }

      expect(subscription.status).to eq("canceled")
    end

    it "still lets a cancellation through, which grants nothing" do
      described_class.apply(event(:subscription_active))
      with_billing_env { described_class.apply(event(:subscription_canceled, occurred_at: t0 + 1.day)) }

      expect(subscription.status).to eq("canceled")
    end
  end

  it "changes nothing for an event type it doesn't act on" do
    expect(described_class.apply(event(nil))).to be_nil
    expect(Subscription.count).to eq(0)
  end
end
