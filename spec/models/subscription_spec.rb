require "rails_helper"

RSpec.describe Subscription do
  let(:user) { create(:user) }

  def entitling?(**attributes)
    subscription = create(:subscription, user: user, **attributes)
    described_class.entitling.exists?(subscription.id)
  end

  it "validates plan and status" do
    expect(build(:subscription, plan: "free")).not_to be_valid
    expect(build(:subscription, status: "trialing")).not_to be_valid
    expect(build(:subscription)).to be_valid
  end

  describe ".entitling" do
    it "includes an active or past-due subscription in its period, or with no period end" do
      expect(entitling?(status: "active", current_period_end: 1.day.from_now)).to be true
      expect(entitling?(status: "past_due", current_period_end: 1.day.from_now)).to be true
      expect(entitling?(status: "active", current_period_end: nil)).to be true
    end

    it "keeps an active or past-due one for 3 days past its period end, as renewals arrive late" do
      expect(entitling?(status: "active", current_period_end: 2.days.ago)).to be true
      expect(entitling?(status: "past_due", current_period_end: 71.hours.ago)).to be true
      expect(entitling?(status: "active", current_period_end: 3.days.ago - 1.minute)).to be false
      expect(entitling?(status: "past_due", current_period_end: 4.days.ago)).to be false
    end

    it "includes a sprint until its 30 days end: it never renews, so it has no grace" do
      expect(entitling?(plan: "sprint", current_period_end: 1.hour.from_now)).to be true
      expect(entitling?(plan: "sprint", current_period_end: 1.minute.ago)).to be false
      expect(entitling?(plan: "sprint", current_period_end: nil)).to be false
    end

    it "includes a canceled subscription until its period ends, with no grace" do
      expect(entitling?(status: "canceled", current_period_end: 1.hour.from_now)).to be true
      expect(entitling?(status: "canceled", current_period_end: 1.minute.ago)).to be false
      expect(entitling?(status: "canceled", current_period_end: nil)).to be false
    end
  end

  describe ".best_for" do
    it "picks the best entitling plan: pro and sprint over creator" do
      create(:subscription, user: user, plan: "creator")
      pro = create(:subscription, user: user, plan: "pro")
      create(:subscription, user: user, plan: "pro", status: "canceled", current_period_end: 1.day.ago)
      expect(described_class.best_for(user)).to eq(pro)
    end

    it "is nil without an entitling subscription" do
      create(:subscription, user: user, status: "canceled", current_period_end: 1.day.ago)
      expect(described_class.best_for(user)).to be_nil
    end
  end
end
