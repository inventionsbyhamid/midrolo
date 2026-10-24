# stub_plan(pipeline?: false, visible_matches_limit: 5): Entitlements.for returns the stub plan with those answers
# changed, so a spec states only what differs from the default.
module PlanHelpers
  def stub_plan(**overrides)
    plan = Class.new(Entitlements::Plan) do
      overrides.each { |name, value| define_method(name) { value } }
    end.new
    allow(Entitlements).to receive(:for).and_return(plan)
    plan
  end
end

RSpec.configure do |config|
  config.include PlanHelpers
end
