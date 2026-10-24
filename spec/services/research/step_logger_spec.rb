require "rails_helper"

RSpec.describe Research::StepLogger do
  let(:report) { create(:report) }
  let(:logger) { described_class.new(report) }
  let(:taste) { Taste::Providers::Fake.new }

  it "creates a running step at the next position, then marks it ok with summary and duration" do
    create(:agent_step, report: report, position: 4)
    seen_status = nil
    result = logger.step("find_on_qloo", "Finding your show on Qloo…", input: "The Money Hour") do |step|
      seen_status = report.agent_steps.order(:position).last.status
      step.output_summary = "Found 4 of 5 shows on Qloo"
      :value
    end

    expect(result).to eq(:value)
    expect(seen_status).to eq("running")
    step = report.agent_steps.order(:position).last
    expect(step).to have_attributes(position: 5, tool: "find_on_qloo", label: "Finding your show on Qloo…",
                                    input_summary: "The Money Hour", status: "ok", output_summary: "Found 4 of 5 shows on Qloo")
    expect(step.duration_ms).to be >= 0
  end

  it "marks the step warning and keeps the warning text when warn! is called" do
    logger.step("map", "Mapping where your listeners live…") do |step|
      step.output_summary = "42 areas"
      step.warn!("Seattle skipped")
    end

    expect(report.agent_steps.last).to have_attributes(status: "warning", output_summary: "42 areas · Seattle skipped")
  end

  it "marks the step error, records the duration and re-raises when the block raises" do
    expect do
      logger.step("audience", "Building your audience's taste profile…") { raise Taste::Unavailable, "Qloo /v2/insights returned HTTP 503" }
    end.to raise_error(Taste::Unavailable)

    step = report.agent_steps.last
    expect(step.status).to eq("error")
    expect(step.duration_ms).to be >= 0
    expect(step.output_summary).to eq("Qloo is unavailable right now.")
  end

  it "uses a short generic message for unexpected errors" do
    expect { logger.step("x", "Doing a thing…") { raise ArgumentError, "a very long internal message" } }.to raise_error(ArgumentError)
    expect(report.agent_steps.last.output_summary).to eq("Something went wrong (ArgumentError).")
  end

  it "counts taste requests made inside the block, and only those" do
    taste.search(query: "Notion", types: [ :brand ]) # outside any step
    logger.step("lookup", "Looking things up…") do
      taste.search(query: "Notion", types: [ :brand ])
      taste.find_tags(query: "business")
    end
    taste.search(query: "Ramp", types: [ :brand ])

    expect(report.reload.taste_calls).to eq(2)
  end

  it "counts nested steps once" do
    logger.step("outer", "Outer…") do
      taste.search(query: "Notion", types: [ :brand ])
      logger.step("inner", "Inner…") { taste.search(query: "Ramp", types: [ :brand ]) }
    end

    expect(report.reload.taste_calls).to eq(2)
    expect(report.agent_steps.pluck(:status)).to eq(%w[ok ok])
  end

  it "ignores taste requests made on other threads" do
    logger.step("lookup", "Looking things up…") do
      Thread.new { taste.search(query: "Notion", types: [ :brand ]) }.join
      taste.search(query: "Ramp", types: [ :brand ])
    end

    expect(report.reload.taste_calls).to eq(1)
  end

  it "still counts taste calls when the block raises" do
    expect do
      logger.step("lookup", "Looking things up…") do
        taste.search(query: "Notion", types: [ :brand ])
        raise Taste::RateLimited, "429"
      end
    end.to raise_error(Taste::RateLimited)

    expect(report.reload.taste_calls).to eq(1)
  end

  describe "Step#optional" do
    it "returns the block value, or nil with a warning on a Qloo outage" do
      values = []
      logger.step("audience", "Building…") do |step|
        values << step.optional("Artists") { :ok }
        values << step.optional("TV shows") { raise Taste::RateLimited, "429" }
      end

      expect(values).to eq([ :ok, nil ])
      expect(report.agent_steps.last).to have_attributes(status: "warning", output_summary: "TV shows skipped: Qloo is rate limiting us.")
    end

    it "lets auth errors through" do
      expect do
        logger.step("audience", "Building…") { |step| step.optional("Artists") { raise Taste::AuthError, "401" } }
      end.to raise_error(Taste::AuthError)
      expect(report.agent_steps.last.status).to eq("error")
    end
  end
end
