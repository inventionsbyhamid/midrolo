require "rails_helper"

RSpec.describe GeneratePitchJob do
  include ActiveJob::TestHelper

  let(:user) { create(:user, judge: true) }
  let(:show) { create(:show, user: user, downloads_per_episode: 1500) }
  let(:report) { create(:report, show: show, kind: "agent", status: "done") }
  let(:match) { create(:sponsor_match, report: report, name: "Fieldnote Coffee") }
  let(:pitch) { Pitch.create!(sponsor_match: match) }
  let(:written) do
    { "subject" => "Hello", "body" => "Body", "angles" => %w[a b c], "offer" => "Offer", "follow_up" => "Follow", "contact_role" => "Founder" }
  end

  def stream_for(record) = Turbo::StreamsChannel.send(:stream_name_from, record)

  it "writes the pitch, marks it done and streams it into the open dialog" do
    allow(Llm).to receive(:mode).and_return(:fake)

    expect { described_class.perform_now(pitch.id) }
      .to have_broadcasted_to(stream_for(pitch)).with { |html|
        expect(html).to include(%(action="replace"), %(target="#{ActionView::RecordIdentifier.dom_id(pitch)}"), "Fieldnote Coffee")
      }
    expect(pitch.reload).to have_attributes(status: "done", model: "fake", error_message: nil)
    expect(pitch.angles.size).to eq(3)
    expect(Pitch.counted).to eq([ pitch ])
  end

  it "stores the live model and the summed cost of every call on the pitch" do
    allow(Llm).to receive(:mode).and_return(:live)
    allow(Pitches::Writer).to receive(:call) do |_match, pitch:|
      SpendEntry.create!(user: user, pitch_id: pitch.id, bucket: "judge", cost_usd: 0.03)
      SpendEntry.create!(user: user, pitch_id: pitch.id, bucket: "judge", cost_usd: 0.02)
      written
    end
    described_class.perform_now(pitch.id)

    expect(pitch.reload).to have_attributes(status: "done", model: Llm.pitch_model, cost_usd: BigDecimal("0.05"), subject: "Hello")
  end

  it "parses a live structured reply into the pitch" do
    allow(Llm).to receive(:mode).and_return(:live)
    old_key = RubyLLM.config.anthropic_api_key
    RubyLLM.config.anthropic_api_key = "test-key"
    AppSettings.set(:judge_reserve_usd, 5)
    AppSettings.set(:promo_budget_usd, 10)
    RubyLLM::Test.stub_response(written.merge("body" => "Hi Fieldnote Coffee team, our listeners love what you make."))

    described_class.perform_now(pitch.id)

    expect(pitch.reload).to have_attributes(status: "done", subject: "Hello", angles: %w[a b c], offer: "Offer",
                                            follow_up: "Follow", contact_role: "Founder", model: Llm.pitch_model)
    expect(pitch.body).to start_with("Hi Fieldnote Coffee team")
    expect(pitch.cost_usd).to eq(SpendEntry.where(pitch_id: pitch.id).sum(:cost_usd))
    expect(SpendEntry.where(pitch_id: pitch.id).count).to eq(1)
  ensure
    RubyLLM.config.anthropic_api_key = old_key
  end

  it "fails with the paused message, uncounted, when the budget refuses" do
    allow(Pitches::Writer).to receive(:call).and_raise(Llm::BudgetExceeded)
    described_class.perform_now(pitch.id)

    expect(pitch.reload).to have_attributes(status: "failed", error_message: "Pitches are paused right now — try again later.")
    expect(Pitches::Writer).to have_received(:call).once
    expect(Pitch.counted).to be_empty
  end

  it "fails with the grounding message when the rewrite is still ungrounded" do
    allow(Pitches::Writer).to receive(:call).and_raise(Pitches::Writer::Ungrounded, "cites 10k")
    described_class.perform_now(pitch.id)

    expect(pitch.reload).to have_attributes(status: "failed", error_message: "We couldn't ground this pitch in your data — try again")
  end

  it "fails with the friendly message, not the grounding one, when the rewrite is still malformed" do
    allow(Pitches::Writer).to receive(:call).and_raise(Pitches::Writer::Malformed, "it needs exactly 3 angles")
    described_class.perform_now(pitch.id)

    expect(pitch.reload).to have_attributes(status: "failed", error_message: Pitch::FAILURE_MESSAGE)
  end

  it "fails, uncounted, when the writer stops because the pitch went stale" do
    allow(Pitches::Writer).to receive(:call).and_raise(Pitches::Writer::Stale)
    described_class.perform_now(pitch.id)

    expect(pitch.reload).to have_attributes(status: "failed", error_message: Pitch::FAILURE_MESSAGE)
    expect(Pitch.counted).to be_empty
  end

  it "re-enqueues on a transient error, with a wait and without sleeping, and keeps the pitch queued for it" do
    allow(Pitches::Writer).to receive(:call).and_raise(RubyLLM::OverloadedError)
    expect_any_instance_of(described_class).not_to receive(:sleep)

    freeze_time do
      wait = described_class::RETRY_WAIT
      expect { described_class.perform_now(pitch.id) } # retry_on adds up to 15% jitter to the wait
        .to have_enqueued_job(described_class).with(pitch.id).at(a_value_between(wait.from_now, (wait * 1.15).from_now))
    end
    expect(pitch.reload).to be_queued
  end

  it "retries a transient error and then succeeds" do
    calls = 0
    allow(Pitches::Writer).to receive(:call) do
      calls += 1
      raise RubyLLM::OverloadedError if calls < 3

      written
    end
    perform_enqueued_jobs { described_class.perform_later(pitch.id) }

    expect(calls).to eq(3)
    expect(pitch.reload.status).to eq("done")
  end

  it "stops after a bounded number of transient errors and fails the pitch" do
    allow(Pitches::Writer).to receive(:call).and_raise(Faraday::TimeoutError)
    expect(Rails.error).to receive(:report).with(an_instance_of(Faraday::TimeoutError), hash_including(handled: true))
    expect { perform_enqueued_jobs { described_class.perform_later(pitch.id) } }.not_to raise_error

    expect(Pitches::Writer).to have_received(:call).exactly(described_class::ATTEMPTS).times
    expect(pitch.reload).to have_attributes(status: "failed", error_message: Pitch::FAILURE_MESSAGE)
  end

  it "fails a pitch that went stale while it waited for a retry, without writing it" do
    calls = 0
    allow(Pitches::Writer).to receive(:call) do
      calls += 1
      pitch.update_column(:created_at, (Pitch::STALE_AFTER + 1.minute).ago)
      raise RubyLLM::RateLimitError
    end
    perform_enqueued_jobs { described_class.perform_later(pitch.id) }

    expect(calls).to eq(1)
    expect(pitch.reload).to have_attributes(status: "failed", error_message: Pitch::FAILURE_MESSAGE)
  end

  it "fails with the friendly message on any other error" do
    allow(Pitches::Writer).to receive(:call).and_raise("boom")
    expect(Rails.error).to receive(:report).with(an_instance_of(RuntimeError), hash_including(handled: true))
    described_class.perform_now(pitch.id)

    expect(pitch.reload).to have_attributes(status: "failed", error_message: Pitch::FAILURE_MESSAGE)
  end

  [ SignalException.new("TERM"), Interrupt.new ].each do |signal|
    it "never leaves the pitch queued when interrupted by #{signal.class}" do
      allow(Pitches::Writer).to receive(:call).and_raise(signal)
      expect { described_class.perform_now(pitch.id) }.to raise_error(signal.class)
      expect(pitch.reload).to have_attributes(status: "failed", error_message: Pitch::FAILURE_MESSAGE)
    end
  end

  it "ignores a pitch that is no longer queued or no longer exists" do
    pitch.update!(status: "done")
    expect(Pitches::Writer).not_to receive(:call)
    described_class.perform_now(pitch.id)
    described_class.perform_now(0)
  end
end
