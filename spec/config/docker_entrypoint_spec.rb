require "rails_helper"
require "open3"

# bin/docker-entrypoint, the production image's entrypoint. Coolify runs the same image twice: the web app with the
# image's command, and midrolo-worker with MIDROLO_PROCESS=jobs, which starts Solid Queue instead (R142). Run here
# against stand-in bin/ scripts that print what ran, so nothing real starts.
RSpec.describe "bin/docker-entrypoint" do
  def run_entrypoint(env, *command)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      FileUtils.cp(Rails.root.join("bin/docker-entrypoint"), File.join(dir, "bin/docker-entrypoint"))
      { "rails" => 'echo "rails $*"', "jobs" => 'echo "jobs $*"', "thrust" => 'shift; echo "thrust"; "$0" "$@"' }.each do |name, body|
        File.write(File.join(dir, "bin", name), "#!/bin/bash\n#{body}\n")
      end
      FileUtils.chmod("+x", Dir[File.join(dir, "bin/*")])
      out, status = Open3.capture2e(env, "bin/docker-entrypoint", *command, chdir: dir)
      expect(status).to be_success, out
      out.lines.map(&:chomp)
    end
  end

  it "prepares the database, then runs the server, for the web app" do
    expect(run_entrypoint({}, "./bin/rails", "server")).to eq([ "rails db:prepare", "rails server" ])
  end

  it "runs Solid Queue, and touches no database, for the worker (MIDROLO_PROCESS=jobs)" do
    expect(run_entrypoint({ "MIDROLO_PROCESS" => "jobs" }, "./bin/thrust", "./bin/rails", "server")).to eq([ "jobs " ])
  end

  it "runs any other command as given" do
    expect(run_entrypoint({}, "./bin/rails", "console")).to eq([ "rails console" ])
  end
end
