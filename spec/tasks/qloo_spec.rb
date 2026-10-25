require "rails_helper"
require "rake"

RSpec.describe "rake qloo:smoke" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("qloo:smoke") }

  let(:task) { Rake::Task["qloo:smoke"] }

  before { task.reenable }

  around do |example|
    saved = ENV["QLOO_API_KEY"]
    example.run
  ensure
    saved.nil? ? ENV.delete("QLOO_API_KEY") : ENV["QLOO_API_KEY"] = saved
  end

  def result(outcomes, aborted: false) = Taste::Smoke::Result.new(outcomes: outcomes, calls: outcomes.size, aborted: aborted)

  it "refuses to run in the test environment, even with a key set, and makes no call" do
    ENV["QLOO_API_KEY"] = "not-a-real-key"

    expect { task.invoke }.to raise_error(SystemExit).and output(/only in development or production/).to_stderr
    expect(a_request(:any, /qloo/)).not_to have_been_made
  end

  it "refuses without a key" do
    ENV.delete("QLOO_API_KEY")
    expect { task.invoke }.to raise_error(SystemExit).and output(/set QLOO_API_KEY/).to_stderr
  end

  it "exits cleanly when every check passes" do
    allow(Taste::Smoke).to receive(:call).and_return(result({ search_podcast: :pass }))
    expect { task.invoke }.not_to raise_error
  end

  it "exits non-zero when a check fails or the run aborts" do
    allow(Taste::Smoke).to receive(:call).and_return(result({ search_podcast: :fail }))
    expect { task.invoke }.to raise_error(SystemExit).and output(/did not pass/).to_stderr

    task.reenable
    allow(Taste::Smoke).to receive(:call).and_return(result({ search_podcast: :pass }, aborted: true))
    expect { task.invoke }.to raise_error(SystemExit)
  end
end
