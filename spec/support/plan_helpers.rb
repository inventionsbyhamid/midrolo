# stub_plan(pipeline?: false, visible_matches_limit: 5): Entitlements.for returns a real plan (Creator by default;
# stub_plan(:pro, ...) for another) for the user asked about, with those answers changed, so a spec states only what
# differs. Usage and in-flight work still come from that user's records, and the gate (Plan#authorize!) reads the
# changed answers.
module PlanHelpers
  def stub_plan(key = :creator, **overrides)
    plan_class = Class.new(Entitlements::Plan) do
      overrides.each { |name, value| define_method(name) { |*| value } }
    end
    allow(Entitlements).to receive(:for) { |user| plan_class.new(key, user: user) }
  end
end

RSpec.configure do |config|
  config.include PlanHelpers
end
