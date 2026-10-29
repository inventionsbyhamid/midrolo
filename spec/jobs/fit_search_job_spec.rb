require "rails_helper"

RSpec.describe FitSearchJob do
  let(:search) { create(:fit_search, query: "Notion", brand: create(:brand, name: "Notion")) }

  it "runs on the reports queue" do
    expect(described_class.new(1).queue_name).to eq("reports")
  end

  it "claims the queued search, runs the agent end to end on the Fake provider, and ends it done" do
    allow(Turbo::StreamsChannel).to receive(:broadcast_refresh_to)

    described_class.perform_now(search.id)

    expect(search.reload).to have_attributes(status: "done")
    expect(search.started_at).to be_present
    expect(search.agent_steps.count).to eq(7)
    expect(Turbo::StreamsChannel).to have_received(:broadcast_refresh_to).with(search).at_least(:twice)
  end

  it "runs a search once when the job is delivered twice" do
    allow(FitSearch::Run).to receive(:call).and_call_original

    2.times { described_class.perform_now(search.id) }

    expect(FitSearch::Run).to have_received(:call).once
  end

  it "does nothing for a search that is gone or already finished" do
    allow(FitSearch::Run).to receive(:call)
    search.update!(status: "done")

    described_class.perform_now(search.id)
    described_class.perform_now(0)

    expect(FitSearch::Run).not_to have_received(:call)
  end

  it "fails the search with a plain message when the agent breaks" do
    allow(FitSearch::Run).to receive(:call).and_raise(NoMethodError, "boom")
    allow(Rails.error).to receive(:report)

    described_class.perform_now(search.id)

    expect(search.reload).to have_attributes(status: "failed", error_message: FitSearch::Run::FAILURE_MESSAGE)
    expect(Rails.error).to have_received(:report).with(an_instance_of(NoMethodError), hash_including(handled: true))
  end

  it "lets a background search wait out Qloo's minute cap" do
    waiting = nil
    allow(FitSearch::Run).to receive(:call) { waiting = Taste::CallGuard.waiting? }

    described_class.perform_now(search.id)

    expect(waiting).to be(true)
  end
end
