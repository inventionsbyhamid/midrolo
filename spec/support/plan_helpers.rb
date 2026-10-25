# stub_plan(pitches: 1, pipeline: false): Entitlements.for gives every user the real Creator plan (stub_plan(:pro, ...)
# for another) with those config/plans.yml values changed. It changes the plan's numbers (Entitlements.limits), not
# its methods, so every answer, the gate (Plan#authorize!) included, follows them; usage still comes from the user's
# own records. A key plans.yml doesn't have raises, so a typo can't pass silently.
module PlanHelpers
  def stub_plan(key = :creator, **values)
    unknown = values.keys - Entitlements::LIMIT_KEYS
    raise ArgumentError, "stub_plan: not a plans.yml limit: #{unknown.join(', ')}" if unknown.any?

    allow(Entitlements).to receive(:limits).and_wrap_original do |original, plan_key|
      plan_key.to_sym == key ? original.call(plan_key).merge(values) : original.call(plan_key)
    end
    allow(Entitlements).to receive(:for) { |user| Entitlements::Plan.new(key, user: user) }
  end
end

RSpec.configure do |config|
  config.include PlanHelpers
end
