require "rails_helper"
require "open3"

# bin/remote-rspec runs the suite over ssh on a test server the operator names. The repo is public, so it names no
# server of its own: without MIDROLO_CI_HOST it stops before any ssh, rsync or remote command.
RSpec.describe "bin/remote-rspec" do
  let(:script) { Rails.root.join("bin/remote-rspec") }

  def run(env, *args) = Open3.capture3(env, "bash", script.to_s, *args)

  it "refuses to run without MIDROLO_CI_HOST, and says what to set" do
    [ [], %w[--clean] ].each do |args|
      _out, err, status = run({ "MIDROLO_CI_HOST" => nil }, *args)

      expect(status.exitstatus).to eq(2)
      expect(err).to include("set MIDROLO_CI_HOST")
    end
  end

  it "treats an empty MIDROLO_CI_HOST as unset" do
    _out, err, status = run({ "MIDROLO_CI_HOST" => "" })

    expect(status.exitstatus).to eq(2)
    expect(err).to include("set MIDROLO_CI_HOST")
  end

  it "has no default host" do
    expect(script.read).to include("HOST=${MIDROLO_CI_HOST:-}\n")
  end
end
