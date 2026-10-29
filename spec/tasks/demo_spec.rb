require "rails_helper"
require "rake"

RSpec.describe "rake demo:setup" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("demo:setup") }

  let(:task) { Rake::Task["demo:setup"] }

  before { task.reenable }

  around do |example|
    original = ENV["DEMO_OWNER_EMAIL"]
    example.run
  ensure
    original.nil? ? ENV.delete("DEMO_OWNER_EMAIL") : ENV["DEMO_OWNER_EMAIL"] = original
  end

  it "makes the demo show and prints its page, and running it again changes nothing" do
    ENV.delete("DEMO_OWNER_EMAIL")
    create(:user, admin: true, email: "admin@example.com")

    expect { task.invoke }.to output(%r{Demo show ready: http://example.com/podcasts/midrolo-demo-show-\w+ \(owner admin@example.com\)}).to_stdout
    task.reenable
    expect { task.invoke }.to output(/Demo show ready/).to_stdout
    expect(Podcast.demo.count).to eq(1)
    expect(Podcast.demo.sole.episodes.count).to eq(6)
  end

  it "uses DEMO_OWNER_EMAIL, and stops with a message when no account has it" do
    ENV["DEMO_OWNER_EMAIL"] = "nobody@example.com"
    expect { task.invoke }.to raise_error(SystemExit).and output(/No account has the email nobody@example.com/).to_stderr
  end
end
