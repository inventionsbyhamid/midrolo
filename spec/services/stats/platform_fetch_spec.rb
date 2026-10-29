require "rails_helper"

RSpec.describe Stats::PlatformFetch do
  let(:cookie) { "AQBsecretcookievalue123456" }
  let!(:session) { create(:service_session, platform: "spotify", credentials: { "sp_dc" => cookie }.to_json) }
  let(:connection) { create(:stat_connection, provider: "spotify", external_id: "4rOoJ6Egrf8K2IrywzwOMk") }
  let(:log) { StringIO.new }

  before { allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(log)) }

  after { described_class.command = nil }

  # Open3.popen3 stubbed: the helper "prints" stdout and stderr and exits with exitstatus. Returns what it was given
  # (the command and options, and what was written to its stdin).
  def stub_helper(stdout:, stderr: "", exitstatus: 0)
    given = {}
    status = instance_double(Process::Status, success?: exitstatus.zero?, exitstatus: exitstatus)
    wait = double("waiter", join: true, value: status, pid: 999_999)
    allow(Open3).to receive(:popen3) do |*args, **options, &block|
      stdin = StringIO.new
      given[:args] = args
      given[:options] = options
      given[:stdin] = stdin
      block.call(stdin, StringIO.new(stdout), StringIO.new(stderr), wait)
    end
    given
  end

  def helper_json(**body) = JSON.generate({ "ok" => true, "platform" => "spotify", "show" => { "id" => "x", "name" => "Ledger" },
                                            "period" => { "start" => "2026-09-29", "end" => "2026-10-28", "days" => 30 },
                                            "metrics" => { "streams" => 12, "followers" => 3 }, "breakdowns" => {} }.merge(body))

  it "sends the request on stdin only, with a 30-day window ending yesterday, and returns the checked result" do
    travel_to Time.utc(2026, 10, 30, 1, 0) do
      given = stub_helper(stdout: helper_json)
      result = described_class.call(connection)

      expect(result).to include("ok" => true, "platform" => "spotify", "metrics" => { "streams" => 12, "followers" => 3 })
      request = JSON.parse(given[:stdin].string)
      expect(request).to eq("platform" => "spotify", "session" => { "sp_dc" => cookie }, "show_id" => "4rOoJ6Egrf8K2IrywzwOMk",
                            "start" => "2026-09-30", "end" => "2026-10-29")
      expect(given[:args].first).to be_a(Hash) # the environment
      expect(given[:args].drop(1)).to eq([ Rails.root.join("bin/platform-stats").to_s ])
      expect(given[:options]).to include(unsetenv_others: true, pgroup: true)
      expect(given[:stdin].string).to include(cookie)
      expect(given[:args].inspect + given[:options].inspect).not_to include(cookie) # stdin only: not argv, not env
      expect(given[:args].first.keys).to all(satisfy { |name| described_class::PASSED_ENV.include?(name) || name.start_with?("PYTHON") })
    end
  end

  it "asks for a longer window when told (the audience over 12 months)" do
    travel_to Time.utc(2026, 10, 30, 1, 0) do
      given = stub_helper(stdout: helper_json)
      described_class.call(connection, days: 365)
      expect(JSON.parse(given[:stdin].string).values_at("start", "end")).to eq(%w[2025-10-30 2026-10-29])
    end
  end

  it "passes on which keys the platform didn't give this time" do
    stub_helper(stdout: helper_json("unavailable" => [ "age", "gender", "bad key!" ]))
    expect(described_class.call(connection)["unavailable"]).to eq(%w[age gender])
  end

  it "keeps only whole, non-negative numbers under plain keys" do
    stub_helper(stdout: helper_json("metrics" => { "streams" => 5, "starts" => -1, "listeners" => 2.5, "bad key!" => 1, "x" => "9" }))
    expect(described_class.call(connection)["metrics"]).to eq("streams" => 5)
  end

  it "reads the helper's errors", :aggregate_failures do
    %w[expired forbidden not_found failed].each do |code|
      stub_helper(stdout: JSON.generate("ok" => false, "error" => code, "message" => "Plain words."))
      expect(described_class.call(connection)).to eq("ok" => false, "error" => code, "message" => "Plain words.")
    end
    stub_helper(stdout: JSON.generate("ok" => false, "error" => "weird", "message" => "Hm."))
    expect(described_class.call(connection)).to include("error" => "failed")
  end

  it "treats an answer that isn't JSON, or no numbers, as failed" do
    stub_helper(stdout: "Traceback (most recent call last): oops", exitstatus: 1)
    expect(described_class.call(connection)).to include("ok" => false, "error" => "failed")
    stub_helper(stdout: "[1, 2]")
    expect(described_class.call(connection)).to include("error" => "failed")
    stub_helper(stdout: helper_json("metrics" => {}))
    expect(described_class.call(connection)).to include("error" => "failed", "message" => "The platform answered without any numbers.")
  end

  it "doesn't trust ok: true from a helper that crashed" do
    stub_helper(stdout: helper_json, exitstatus: 1)
    expect(described_class.call(connection)).to include("ok" => false, "error" => "failed")
  end

  it "never logs the session, even when the helper writes it to stderr or into its message" do
    stub_helper(stdout: JSON.generate("ok" => false, "error" => "failed", "message" => "bad cookie #{cookie}"),
                stderr: "debug: sp_dc=#{cookie}", exitstatus: 1)
    result = described_class.call(connection)

    expect(log.string).to include("[Stats::PlatformFetch]").and include("[FILTERED]")
    expect(log.string).not_to include(cookie)
    expect(result.to_s).not_to include(cookie)
  end

  it "reports a crash by class only, never its message" do
    allow(Open3).to receive(:popen3).and_raise(ArgumentError, "boom #{cookie}")
    result = described_class.call(connection)
    expect(result).to include("error" => "failed", "message" => "Something went wrong reading the numbers (ArgumentError).")
    expect(log.string).not_to include(cookie)
  end

  it "says so when the helper isn't installed" do
    described_class.command = [ Rails.root.join("tmp/no-such-helper").to_s ]
    expect(described_class.call(connection)).to include("error" => "failed", "message" => "The stats helper isn't installed on this server.")
  end

  it "asks nothing without a working session" do
    expect(Open3).not_to receive(:popen3)
    session.update!(status: "expired")
    expect(described_class.call(connection)).to include("error" => "unavailable")
    session.destroy!
    expect(described_class.call(connection)).to include("error" => "unavailable")
  end

  it "doesn't quote a session it can't parse" do
    session.update!(credentials: "{not json #{cookie}")
    result = described_class.call(connection)
    expect(result).to include("error" => "unavailable")
    expect(result.to_s + log.string).not_to include(cookie)
  end

  context "with a real process" do
    it "reads stdin and stdout through Open3, in a bare environment" do
      ENV["MIDROLO_SPEC_SECRET"] = "leak"
      described_class.command = [ "sh", "-c", <<~SH ]
        read -r request
        case "$request" in *#{cookie}*) ;; *) exit 9 ;; esac
        [ -z "$MIDROLO_SPEC_SECRET" ] || exit 8
        printf '%s' '#{helper_json}'
      SH
      expect(described_class.call(connection)).to include("ok" => true, "metrics" => { "streams" => 12, "followers" => 3 })
    ensure
      ENV.delete("MIDROLO_SPEC_SECRET")
    end

    it "kills a helper that runs past the timeout, with everything it started" do
      described_class.command = [ "sh", "-c", "sleep 30 & sleep 30" ]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = described_class.call(connection, timeout: 0.5)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
      expect(result).to include("ok" => false, "error" => "failed", "message" => "The platform took longer than 0.5 seconds to answer.")
      expect(log.string).to include("timeout")
    end
  end
end
