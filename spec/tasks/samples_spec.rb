require "rails_helper"
require "rake"

RSpec.describe "rake samples:generate" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("samples:generate") }

  let(:task) { Rake::Task["samples:generate"] }

  before { task.reenable }

  around do |example|
    original = ENV["FORCE"]
    example.run
  ensure
    original.nil? ? ENV.delete("FORCE") : ENV["FORCE"] = original
  end

  def result(outcome) = Samples::Generate::Result.new(slug: "sample-one", outcome: outcome, message: "")

  it "generates the samples, skipping done ones" do
    ENV.delete("FORCE")
    allow(Samples::Generate).to receive(:call).and_return([ result(:done), result(:skipped) ])

    expect { task.invoke }.to output(/1 done, 1 skipped, 0 failed/).to_stdout
    expect(Samples::Generate).to have_received(:call).with(force: false)
  end

  it "runs every sample again with FORCE=1" do
    ENV["FORCE"] = "1"
    allow(Samples::Generate).to receive(:call).and_return([ result(:done) ])

    expect { task.invoke }.to output(/1 done, 0 skipped, 0 failed/).to_stdout
    expect(Samples::Generate).to have_received(:call).with(force: true)
  end

  it "exits non-zero when a sample failed" do
    ENV.delete("FORCE")
    allow(Samples::Generate).to receive(:call).and_return([ result(:failed) ])

    expect { task.invoke }.to raise_error(SystemExit)
      .and output(/0 done, 0 skipped, 1 failed/).to_stdout
      .and output(/Samples failed: sample-one/).to_stderr
  end
end
