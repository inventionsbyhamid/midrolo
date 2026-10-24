require "rails_helper"
require "rake"

RSpec.describe "rake eval:run" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("eval:run") }

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  before do
    Taste::Provider.reset!
    Podcasts::Directory.reset!
    Rake::Task["eval:run"].reenable
  end

  it "runs an agent report per eval show (dev bucket) on Fake providers and passes every expectation" do
    shows = YAML.load_file(Rails.root.join("config/eval_shows.yml")).fetch("shows")
    expect(shows.size).to eq(2)

    expect { Rake::Task["eval:run"].invoke }.to output(%r{PASS provenance.*PASS provenance.*2/2 shows passed}m).to_stdout

    reports = Report.where(kind: "agent")
    expect(reports.count).to eq(2)
    expect(reports.pluck(:spend_bucket).uniq).to eq([ "dev" ])
    expect(reports.pluck(:status).uniq).to eq([ "done" ])
  end

  it "says which path it evaluates" do
    expect { Rake::Task["eval:run"].invoke }.to output(/LLM path: scripted runner \(fake LLM mode\)/).to_stdout
  end

  it "refuses EVAL_MODE=agent without an API key" do
    old = ENV.to_h.slice("EVAL_MODE", "ANTHROPIC_API_KEY")
    ENV["EVAL_MODE"] = "agent"
    ENV["ANTHROPIC_API_KEY"] = ""
    expect { Rake::Task["eval:run"].invoke }.to raise_error(SystemExit).and output(/needs ANTHROPIC_API_KEY/).to_stderr
    expect(Report.count).to eq(0)
  ensure
    %w[EVAL_MODE ANTHROPIC_API_KEY].each { |k| ENV[k] = old[k] }
  end

  it "forces the agent path with EVAL_MODE=agent when a key is present, even if LLM_PROVIDER=fake" do
    old = ENV.to_h.slice("EVAL_MODE", "ANTHROPIC_API_KEY", "LLM_PROVIDER")
    ENV.update("EVAL_MODE" => "agent", "ANTHROPIC_API_KEY" => "test-key", "LLM_PROVIDER" => "fake")
    modes = []
    allow(Research::Run).to receive(:call) { |report| modes << Llm.mode; report.mark_failed!; nil }

    capture_stdout { expect { Rake::Task["eval:run"].invoke }.to raise_error(SystemExit).and output(/Eval failed/).to_stderr }
    expect(modes).to eq(%i[live live])
    expect(ENV["LLM_PROVIDER"]).to eq("fake") # restored afterwards
  ensure
    %w[EVAL_MODE ANTHROPIC_API_KEY LLM_PROVIDER].each { |k| ENV[k] = old[k] }
  end

  it "reports a failed expectation and exits non-zero" do
    path = Rails.root.join("tmp/eval_failing.yml")
    File.write(path, { "shows" => [ { "directory_id" => "fake-3", "expect" => { "min_matches" => 99 } } ] }.to_yaml)

    output = capture_stdout do
      expect { Rake::Task["eval:run"].invoke(path.to_s) }.to raise_error(SystemExit).and output(/Eval failed/).to_stderr
    end
    expect(output).to match(%r{FAIL min_matches.*0/1 shows passed}m)
  ensure
    FileUtils.rm_f(path)
  end
end
