require "rails_helper"

# The paced seed: Catalog::SeedProgress.start! queues the first step, each step reads one Qloo page (the Fake taste
# provider and the demo directory, made-up shows) and queues the next after the interval. No real Qloo data.
RSpec.describe Catalog::SeedStepJob do
  include ActiveJob::TestHelper

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    freeze_time
    Podcasts::Directory.reset!
    allow(Rails).to receive(:cache).and_return(cache)
    # Directory pacing would sleep a second between searches (the default sleeper runs on the class).
    allow(Catalog::SeedFromQloo).to receive(:sleep)
  end

  def progress = Catalog::SeedProgress.current
  def queued_steps = enqueued_jobs.select { |job| job["job_class"] == described_class.name }
  def step_state(job) = ActiveJob::Arguments.deserialize(job["arguments"]).first

  it "starts one chain on the catalog queue at low priority, spreading the expected pages over the hours" do
    start = Catalog::SeedProgress.start!(target: 1000, hours: 6)

    expect(start.status).to eq(:started)
    # 1,000 shows at about 25 matches a page is 40 pages: one every 9 minutes for 6 hours.
    expect(progress).to have_attributes(status: "running", target: 1000, interval: 540, pages: 0, linked: 0)
    expect(progress.finish_by).to eq(6.hours.from_now)
    expect(described_class).to have_been_enqueued.on_queue("catalog").at_priority(20).exactly(:once)
    state = step_state(queued_steps.first)
    expect(state).to include("target" => 1000, "tag_index" => 0, "offset" => 0, "exhausted" => [], "interval" => 540)
    expect(state["chain"]).to eq(progress.chain)
  end

  it "does nothing when a chain is running already, or the target is linked already" do
    Catalog::SeedProgress.start!(target: 1000, hours: 6)
    expect(Catalog::SeedProgress.start!(target: 500, hours: 2).status).to eq(:running)
    expect(queued_steps.size).to eq(1)

    travel 2.hours # nothing ran: the chain stalled, so a new one may start
    expect(Catalog::SeedProgress.start!(target: 1000, hours: 6).status).to eq(:started)

    Catalog::SeedProgress.stop!
    create(:podcast, qloo_entity_id: "Q-1")
    expect(Catalog::SeedProgress.start!(target: 1, hours: 6).status).to eq(:reached)
  end

  it "reads one page a step, records the progress and queues the next step after the interval" do
    Catalog::SeedProgress.start!(target: 1000, hours: 6)
    first = step_state(queued_steps.first)
    clear_enqueued_jobs

    described_class.perform_now(first)

    expect(progress).to have_attributes(status: "running", pages: 1, tag: "urn:tag:genre:media:business", offset: 0)
    expect(progress.matched).to be_positive
    expect(progress.linked).to eq(Podcast.where.not(qloo_entity_id: nil).count)
    expect(progress.next_run_at).to eq(progress.interval.seconds.from_now)
    expect(queued_steps.size).to eq(1)
    following = queued_steps.first
    expect(following["scheduled_at"]).to be_present
    expect(Time.zone.parse(following["scheduled_at"].to_s)).to be_within(1.second).of(progress.interval.seconds.from_now)
    expect(step_state(following)).to include("chain" => first["chain"], "tag_index" => 1, "offset" => 0)
  end

  it "runs the chain to its end and says why it stopped" do
    Catalog::SeedProgress.start!(target: 3, hours: 1)
    10.times do
      job = queued_steps.first or break
      clear_enqueued_jobs
      described_class.perform_now(step_state(job))
    end

    expect(progress).to have_attributes(status: "finished", stopped: "target", linked: 3, next_run_at: nil)
    expect(progress.stop_reason).to eq("the target was reached")
    expect(queued_steps).to be_empty
  end

  it "picks up where the last chain stopped, and starts over once the tags ran out" do
    Catalog::SeedProgress.start!(target: 1000, hours: 6)
    described_class.perform_now(step_state(queued_steps.first))
    Catalog::SeedProgress.stop!
    clear_enqueued_jobs

    expect(Catalog::SeedProgress.start!(target: 1000, hours: 6).status).to eq(:started)
    expect(step_state(queued_steps.sole)).to include("tag_index" => 1, "offset" => 0)

    Catalog::SeedProgress.update!(progress.data.merge("status" => "finished", "stopped" => "exhausted"))
    clear_enqueued_jobs
    Catalog::SeedProgress.start!(target: 1000, hours: 6)
    expect(step_state(queued_steps.sole)).to include("tag_index" => 0, "offset" => 0, "exhausted" => [])
  end

  it "ends quietly for a chain that isn't the running one (stopped, or replaced)" do
    Catalog::SeedProgress.start!(target: 1000, hours: 6)
    state = step_state(queued_steps.first)
    clear_enqueued_jobs
    allow(Taste::Provider.current).to receive(:recommend).and_call_original

    described_class.perform_now(state.merge("chain" => "someone-else"))
    expect(Catalog::SeedProgress.stop!).to be(true)
    described_class.perform_now(state)

    expect(Taste::Provider.current).not_to have_received(:recommend)
    expect(queued_steps).to be_empty
    expect(progress).to have_attributes(status: "stopped", stop_reason: "it was stopped by hand")
  end

  it "stops at Qloo's call caps" do
    Catalog::SeedProgress.start!(target: 1000, hours: 6)
    state = step_state(queued_steps.first)
    clear_enqueued_jobs
    allow(Taste::Provider.current).to receive(:recommend).and_raise(Taste::CallCapReached, "the daily limit")

    described_class.perform_now(state)
    expect(progress).to have_attributes(status: "finished", stopped: "qloo_limit")
    expect(queued_steps).to be_empty
  end

  it "tries the same page again after an unexpected error, and gives up after a few in a row" do
    Catalog::SeedProgress.start!(target: 1000, hours: 6)
    state = step_state(queued_steps.first)
    clear_enqueued_jobs
    allow(Catalog::SeedFromQloo).to receive(:read_page).and_raise(ActiveRecord::StatementInvalid, "boom")
    allow(Rails.error).to receive(:report)

    described_class.perform_now(state)
    retry_state = step_state(queued_steps.sole)
    expect(retry_state).to include("tag_index" => 0, "offset" => 0, "errors" => 1)
    expect(progress).to have_attributes(status: "running", pages: 0, error: "ActiveRecord::StatementInvalid: boom")

    clear_enqueued_jobs
    described_class.perform_now(retry_state.merge("errors" => described_class::MAX_ERRORS - 1))
    expect(queued_steps).to be_empty
    expect(progress).to have_attributes(status: "finished", stopped: "error")
    expect(Rails.error).to have_received(:report).twice
  end

  it "spreads the pages left over the time left, at the matches a page really brings" do
    finish_by = 6.hours.from_now
    expect(Catalog::SeedProgress.interval_for(remaining: 1000, finish_by: finish_by, pages: 0, matched: 0)).to eq(540)
    # 10 pages brought 100 matches: 90 pages left for the 900 still missing, in 5 hours.
    travel 1.hour
    expect(Catalog::SeedProgress.interval_for(remaining: 900, finish_by: finish_by, pages: 10, matched: 100)).to eq(200)
    expect(Catalog::SeedProgress.interval_for(remaining: 900, finish_by: 1.minute.ago, pages: 10, matched: 100))
      .to eq(Catalog::SeedProgress::MIN_INTERVAL.to_i)
    expect(Catalog::SeedProgress.interval_for(remaining: 1, finish_by: finish_by, pages: 10, matched: 100))
      .to eq(Catalog::SeedProgress::MAX_INTERVAL.to_i)
  end
end
