require "rails_helper"

# bin/ci's steps (config/ci.rb), read through a stand-in for ActiveSupport::ContinuousIntegration that records them.
# R127: the repo is public and judged on reproducibility, so the suite runs locally by default; the operator's remote
# lane (bin/remote-rspec, which needs the VPN) only when asked.
RSpec.describe "bin/ci" do
  def steps(env)
    recorded = []
    ci = Object.new
    ci.define_singleton_method(:run) { |&block| instance_eval(&block) }
    ci.define_singleton_method(:step) { |title, *command| recorded << [ title, *command ] }
    ci.define_singleton_method(:success?) { true }
    stub_const("CI", ci)
    stub_const("ENV", ENV.to_h.except("REMOTE_RSPEC", "LOCAL_RSPEC").merge(env))
    load Rails.root.join("config/ci.rb").to_s
    recorded
  end

  it "runs RSpec here by default" do
    expect(steps({}).assoc("Tests: RSpec")).to eq([ "Tests: RSpec", "bundle exec rspec" ])
  end

  it "runs it on the remote lane only with REMOTE_RSPEC=1" do
    expect(steps("REMOTE_RSPEC" => "1").assoc("Tests: RSpec")).to eq([ "Tests: RSpec", "bin/remote-rspec" ])
    expect(steps("LOCAL_RSPEC" => "1").assoc("Tests: RSpec")).to eq([ "Tests: RSpec", "bundle exec rspec" ])
  end
end
