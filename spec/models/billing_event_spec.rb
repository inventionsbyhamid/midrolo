require "rails_helper"

RSpec.describe BillingEvent do
  def event(id: "msg_1", provider: "dodo")
    Billing::Event.new(id: id, provider: provider, type: :subscription_active, name: "subscription.active",
                       raw: { "type" => "subscription.active" })
  end

  describe ".record!" do
    it "stores a webhook once per provider and event id" do
      first = described_class.record!(event)

      expect(described_class.record!(event)).to eq(first)
      expect(described_class.record!(event(provider: "fake"))).not_to eq(first)
      expect(described_class.count).to eq(2)
      expect(first).to have_attributes(event_type: "subscription.active", payload: { "type" => "subscription.active" },
                                       processed_at: nil)
    end
  end

  it "is processed once marked, with an optional note" do
    row = described_class.record!(event)
    row.mark_processed!("No user")

    expect(row.reload).to be_processed
    expect(row.error_message).to eq("No user")
  end
end
