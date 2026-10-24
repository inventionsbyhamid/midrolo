require "rails_helper"

RSpec.describe Entitlements do
  subject(:plan) { described_class.for(build(:user)) }

  it "returns the stub free plan (Task 16 replaces the values)" do
    expect(plan.key).to eq(:free)
    expect(plan.max_shows).to eq(1)
    expect(plan.can_run?(:snapshot)).to be true
    expect(plan.agent_reports_left).to eq(99)
    expect(plan.snapshots_left).to eq(99)
    expect(plan.pitches_left).to eq(99)
    expect(plan.can_pitch?).to be true
    expect(plan.visible_matches_limit).to eq(50)
    expect(plan.kit_badge?).to be true
    expect(plan.csv_export?).to be false
    expect(plan.scan_limit).to eq(8)
  end

  it "defines NotAllowed with a reason" do
    error = described_class::NotAllowed.new(:limit)
    expect(error).to be_a(StandardError)
    expect(error.reason).to eq(:limit)
  end
end
