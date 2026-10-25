require "rails_helper"

RSpec.describe Taste::CallGuard do
  let(:store) { ActiveSupport::Cache::MemoryStore.new }
  let(:now) { Time.utc(2026, 10, 25, 16, 20, 5) }
  let(:clock) { -> { now } }
  let(:guard) { described_class.new(store: store, clock: clock) }

  around do |example|
    saved = ENV["QLOO_MAX_PER_MINUTE"]
    ENV.delete("QLOO_MAX_PER_MINUTE")
    example.run
  ensure
    saved.nil? ? ENV.delete("QLOO_MAX_PER_MINUTE") : ENV["QLOO_MAX_PER_MINUTE"] = saved
  end

  it "defaults to 30 calls a minute and the admin's daily limit of 100 (R92)" do
    expect(described_class.per_minute).to eq(30)
    expect(described_class.daily_limit).to eq(100)

    ENV["QLOO_MAX_PER_MINUTE"] = "12"
    AppSettings.set(:qloo_daily_call_limit, 250)
    expect(described_class.per_minute).to eq(12)
    expect(described_class.daily_limit).to eq(250)
  end

  it "counts each call it allows" do
    3.times { guard.acquire! }
    expect(guard.usage).to have_attributes(today: 3, minute: 3, daily_limit: 100, per_minute: 30)
  end

  it "refuses the call past the minute cap, a RateLimited, and allows calls again the next minute" do
    ENV["QLOO_MAX_PER_MINUTE"] = "2"
    2.times { guard.acquire! }

    expect { guard.acquire! }.to raise_error(Taste::CallCapReached) { |error| expect(error).to be_a(Taste::RateLimited) }
    expect(guard.usage).to have_attributes(minute: 2, today: 2)

    later = described_class.new(store: store, clock: -> { Time.utc(2026, 10, 25, 16, 21, 0) })
    later.acquire!
    expect(later.usage).to have_attributes(minute: 1, today: 3)
  end

  it "refuses the call past the daily limit until the next UTC day, giving the refused slot back" do
    AppSettings.set(:qloo_daily_call_limit, 2)
    2.times { guard.acquire! }

    2.times { expect { guard.acquire! }.to raise_error(Taste::CallCapReached, /daily limit of 2/) }
    expect(guard.usage).to have_attributes(today: 2, minute: 2)

    tomorrow = described_class.new(store: store, clock: -> { Time.utc(2026, 10, 26, 0, 0, 1) })
    expect { tomorrow.acquire! }.not_to raise_error
  end

  it "refuses every call when the daily limit is 0" do
    AppSettings.set(:qloo_daily_call_limit, 0)
    expect { guard.acquire! }.to raise_error(Taste::CallCapReached)
    expect(guard.usage.today).to eq(0)
  end

  it "fails closed when the store can't count" do
    null = described_class.new(store: ActiveSupport::Cache::NullStore.new, clock: clock)
    expect { null.acquire! }.to raise_error(Taste::CallCapReached, /counter/)
  end

  describe "the free share (R95, R108)" do
    before { AppSettings.set(:qloo_daily_call_limit, 10) }

    it "defaults to 40% of the daily limit, as set in admin" do
      expect(described_class.free_share).to eq(BigDecimal("0.4"))
      expect(guard.usage).to have_attributes(free_today: 0, free_limit: 4)
      AppSettings.set(:qloo_free_share, "0.25")
      expect(described_class.free_share).to eq(BigDecimal("0.25"))
      expect(guard.usage.free_limit).to eq(2)
    end

    it "lets capped runs (free and promo users, R108) use at most their share, while other runs use the rest of the day" do
      described_class.lane(:capped) do
        4.times { guard.acquire! }
        expect { guard.acquire! }.to raise_error(Taste::FreeShareSpent) { |error| expect(error).to be_a(Taste::CallCapReached) }
      end
      expect(guard.usage).to have_attributes(today: 4, free_today: 4)

      6.times { guard.acquire! }
      expect { guard.acquire! }.to raise_error(Taste::CallCapReached)
      expect(guard.usage).to have_attributes(today: 10, free_today: 4)
    end

    it "still holds free runs to the daily limit when other runs used it up" do
      10.times { guard.acquire! }
      described_class.lane(:capped) { expect { guard.acquire! }.to raise_error(Taste::CallCapReached) }
      expect(guard.usage).to have_attributes(today: 10, free_today: 0)
    end

    it "gives no free calls at a share of 0, and reads a bad share as the default" do
      AppSettings.set(:qloo_free_share, "0")
      described_class.lane(:capped) { expect { guard.acquire! }.to raise_error(Taste::FreeShareSpent) }
      AppSettings.set(:qloo_free_share, "1.5")
      expect(described_class.free_share).to eq(BigDecimal("0.4"))
    end

    it "says a capped run would be refused once its share, or the whole day, is used up (R108)" do
      expect(guard).not_to be_capped_spent
      described_class.lane(:capped) { 4.times { guard.acquire! } }
      expect(guard).to be_capped_spent

      other = described_class.new(store: ActiveSupport::Cache::MemoryStore.new, clock: clock)
      10.times { other.acquire! }
      expect(other).to be_capped_spent
    end

    it "sets the lane for the block only, on this thread, even when the block raises" do
      expect(described_class.current_lane).to be_nil
      expect { described_class.lane(:capped) { raise ArgumentError } }.to raise_error(ArgumentError)
      expect { described_class.lane(:free) { nil } }.to raise_error(ArgumentError, /unknown call lane/)
      expect(described_class.current_lane).to be_nil
      described_class.lane(:capped) do
        expect(described_class.current_lane).to eq(:capped)
        expect(Thread.new { described_class.current_lane }.value).to be_nil
        described_class.lane(nil) { expect(described_class.current_lane).to be_nil }
        expect(described_class.current_lane).to eq(:capped)
      end
    end
  end

  describe "waiting for the next minute in a background job (R109)" do
    let(:sleeps) { [] }

    before { ENV["QLOO_MAX_PER_MINUTE"] = "2" }

    def waiting_guard(start)
      time = start
      described_class.new(store: store, clock: -> { time }, sleeper: ->(seconds) { sleeps << seconds; time += seconds })
    end

    it "waits for the next UTC minute when the minute cap is reached, then takes the slot" do
      guard = waiting_guard(Time.utc(2026, 10, 25, 16, 20, 45))
      2.times { guard.acquire! }
      described_class.waiting { guard.acquire! }

      expect(sleeps.size).to eq(1)
      expect(sleeps.first).to be_within(0.5).of(15)
      expect(guard.usage).to have_attributes(minute: 1, today: 3)
    end

    it "waits at most twice for one call, then refuses" do
      ENV["QLOO_MAX_PER_MINUTE"] = "0"
      guard = waiting_guard(Time.utc(2026, 10, 25, 16, 20, 45))

      described_class.waiting { expect { guard.acquire! }.to raise_error(Taste::MinuteCapReached) }
      expect(sleeps.size).to eq(2)
    end

    it "never waits outside a background job" do
      guard = waiting_guard(Time.utc(2026, 10, 25, 16, 20, 45))
      2.times { guard.acquire! }

      expect(described_class).not_to be_waiting
      expect { guard.acquire! }.to raise_error(Taste::MinuteCapReached) { |error| expect(error).to be_a(Taste::CallCapReached) }
      expect(sleeps).to be_empty
    end

    it "never waits for the daily cap or the capped share, which refuse at once" do
      AppSettings.set(:qloo_daily_call_limit, 1)
      guard = waiting_guard(Time.utc(2026, 10, 25, 16, 20, 45))
      guard.acquire!

      described_class.waiting do
        expect { guard.acquire! }.to raise_error(Taste::CallCapReached, /daily limit/)
        AppSettings.set(:qloo_free_share, "0")
        described_class.lane(:capped) { expect { guard.acquire! }.to raise_error(Taste::CallCapReached) }
      end
      expect(sleeps).to be_empty
    end

    it "turns waiting on for the block only" do
      described_class.waiting { expect(described_class).to be_waiting }
      expect(described_class).not_to be_waiting
    end
  end

  describe "a run's hard ceiling (R130)" do
    it "refuses inside a reached ceiling before taking any slot, and only there" do
      spent = false
      described_class.run_ceiling(-> { spent }) do
        guard.acquire!
        spent = true
        expect { guard.acquire! }.to raise_error(Taste::RunBudgetSpent) { |error| expect(error).not_to be_a(Taste::RateLimited) }
      end

      expect(guard.usage).to have_attributes(today: 1, minute: 1)
      guard.acquire! # outside the run
      expect(guard.usage.today).to eq(2)
    end
  end

  it "logs each refusal" do
    AppSettings.set(:qloo_daily_call_limit, 0)
    allow(Rails.logger).to receive(:warn)
    expect { guard.acquire! }.to raise_error(Taste::CallCapReached)
    expect(Rails.logger).to have_received(:warn).with(a_string_including("[Qloo]", "daily limit of 0"))
  end
end
