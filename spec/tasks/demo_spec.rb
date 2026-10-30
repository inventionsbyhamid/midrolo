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

    expect { task.invoke }.to output(%r{Demo show ready: http://example.com/podcasts/midrolo-demo-show \(owner admin@example.com\)}).to_stdout
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

# bin/setup runs it after db:prepare: the demo catalog, the demo admin and the demo show, in development demo mode only.
RSpec.describe "rake demo:seed" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("demo:seed") }

  before { %w[demo:seed demo:setup catalog:seed].each { |name| Rake::Task[name].reenable } }

  around do |example|
    original = ENV.delete("DEMO_OWNER_EMAIL")
    example.run
  ensure
    ENV["DEMO_OWNER_EMAIL"] = original unless original.nil?
  end

  it "does nothing outside development demo mode, and says why" do
    allow(Catalog::SeedFromQloo).to receive(:call)

    expect { Rake::Task["demo:seed"].invoke }.to output("demo:seed: skipped: development only (this is test)\n").to_stdout
    expect(Catalog::SeedFromQloo).not_to have_received(:call)
    expect(User.count).to eq(0)
    expect(Podcast.demo).to be_empty
  end

  it "seeds the demo catalog, makes demo-admin@midrolo.test an admin who owns the demo show, and runs again safely" do
    allow(DemoSeed).to receive(:skip_reason).and_return(nil)
    result = Catalog::SeedFromQloo::Result.new(linked: 16, added: 16, matched: 16, missed: 0, pages: 1, stopped: :target)
    allow(Catalog::SeedFromQloo).to receive(:call).and_return(result)

    expect { Rake::Task["demo:seed"].invoke }.to output(
      /catalog:seed: 16 linked.*demo:seed: demo-admin@midrolo.test is an admin.*Demo show ready: .*\(owner demo-admin@midrolo.test\)/m
    ).to_stdout
    expect(Catalog::SeedFromQloo).to have_received(:call).with(hash_including(target: 16))

    %w[demo:seed demo:setup catalog:seed].each { |name| Rake::Task[name].reenable }
    expect { Rake::Task["demo:seed"].invoke }.to output(/Demo show ready/).to_stdout
    expect(User.where(admin: true).pluck(:email)).to eq([ "demo-admin@midrolo.test" ])
    expect(Podcast.demo.sole.owner_show.user.email).to eq("demo-admin@midrolo.test")
  end
end
