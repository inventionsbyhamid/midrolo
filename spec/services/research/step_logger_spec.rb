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

  it "does not count cached taste requests" do
    logger.step("lookup", "Looking things up…") do
      ActiveSupport::Notifications.instrument("request.taste", path: "/search", cached: true, status: 200)
      ActiveSupport::Notifications.instrument("request.taste", path: "/search", cached: false, status: 200)
    end

    expect(report.reload.taste_calls).to eq(1)
    expect(logger.uncached_calls).to eq(1)
  end

  it "counts concurrent steps on different threads separately" do
    inside = Queue.new
    release = Queue.new
    other = Thread.new do
      logger.step("a", "On another thread…") do
        taste.search(query: "Notion", types: [ :brand ])
        inside << true
        release.pop
      end
    end
    inside.pop
    logger.step("b", "On this thread…") { 2.times { taste.search(query: "Ramp", types: [ :brand ]) } }
    release << true
    other.join

    expect(report.reload.taste_calls).to eq(3)
    expect(logger.uncached_calls).to eq(3)
  end

  it "finishes the step when the block exits with return" do
    helper = Class.new do
      def run(logger) = logger.step("x", "Leaving early…") { return :early }
    end

    expect(helper.new.run(logger)).to eq(:early)
    expect(report.agent_steps.last).to have_attributes(status: "ok")
    expect(report.agent_steps.last.duration_ms).to be >= 0
  end

  it "finishes the step when the block exits with throw" do
    catch(:done) { logger.step("x", "Throwing…") { throw :done } }
    expect(report.agent_steps.last.status).to eq("ok")
  end

  it "never lets a failed taste_calls update mask the block's own error" do
    allow(report).to receive(:increment!).and_raise(ActiveRecord::ConnectionNotEstablished, "db gone")
    allow(Rails.error).to receive(:report)

    expect do
      logger.step("x", "Failing…") do
        taste.search(query: "Notion", types: [ :brand ])
        raise Taste::Unavailable, "503"
      end
    end.to raise_error(Taste::Unavailable)
    expect(Rails.error).to have_received(:report).with(instance_of(ActiveRecord::ConnectionNotEstablished), hash_including(handled: true))
  end

  it "treats a request Qloo can't use (400) or doesn't support (403) like empty in optional work (M2, M7)" do
    results = []
    logger.step("audience", "Building…") do |step|
      results << step.optional("Leans") { raise Taste::Unsupported, "Qloo /v2/insights returned HTTP 403" }
      results << step.optional("Category pass") { raise Taste::BadRequest, "Qloo /v2/insights returned HTTP 400" }
    end

    expect(results).to eq([ nil, nil ])
    expect(report.agent_steps.last).to have_attributes(
      status: "warning",
      output_summary: "Leans skipped: Qloo doesn't support that request. · Category pass skipped: Qloo couldn't use that request."
    )
  end

  it "says taste data is busy when our own call guard refused an optional call (R92)" do
    logger.step("audience", "Building…") { |step| step.optional("Leans") { raise Taste::CallCapReached, "daily limit" } }
    expect(report.agent_steps.last.output_summary).to eq("Leans skipped: Taste data is busy right now.")
  end

  describe "research budget" do
    let(:logger) { described_class.new(report, max_taste_calls: 2) }

    it "reads the default budget from config/llm.yml" do
      expect(described_class.new(report).max_taste_calls).to eq(Rails.application.config_for(:llm).dig(:research, :max_taste_calls))
      expect(described_class.new(report).max_taste_calls).to eq(60)
    end

    it "skips optional sub-calls once the run has spent its uncached calls, but never core calls" do
      results = []
      logger.step("audience", "Building…") do |step|
        2.times { taste.search(query: "Notion", types: [ :brand ]) } # core calls reach the budget
        results << step.optional("Artists") { taste.search(query: "Nova", types: [ :artist ]) }
        results << taste.search(query: "Ramp", types: [ :brand ]).first.name # core still runs
      end

      expect(results).to eq([ nil, "Ramp" ])
      expect(logger.uncached_calls).to eq(3)
      expect(logger.budget_spent?).to be(true)
      expect(report.agent_steps.last).to have_attributes(status: "warning", output_summary: "Skipped to stay within research budget")
    end
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
