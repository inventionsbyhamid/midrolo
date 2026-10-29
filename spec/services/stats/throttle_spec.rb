require "rails_helper"

RSpec.describe Stats::Throttle do
  let!(:session) { create(:service_session, platform: "spotify") }
  let(:t0) { Time.utc(2026, 10, 30, 12, 0, 0) }

  around { |example| travel_to(t0) { example.run } }

  def reserve(at = Time.current, **options) = described_class.reserve("spotify", now: at, **options)

  def finish(result, at = Time.current) = described_class.finish("spotify", result, now: at)

  # Runs that started at these times, as if they had happened.
  def ran_at(*times) = session.update_columns(run_log: times.map(&:to_i))

  def ok = spotify_result

  describe "one run at a time, then a gap" do
    it "lets the first run start and records it" do
      slot = reserve
      expect(slot).to have_attributes(allowed?: true, at: t0)
      expect(session.reload.run_log).to eq([ t0.to_i ])
    end

    it "holds the platform while a run lasts, then waits the gap plus up to the jitter after it ends" do
      reserve
      expect(reserve(t0 + 50.seconds, book: false)).not_to be_allowed # still running (the lease)

      finish(ok, t0 + 5.seconds)
      expect(session.reload.next_run_at).to be_between(t0 + 35.seconds, t0 + 50.seconds) # 30 s plus 0 to 15 s
      expect(reserve(t0 + 34.seconds, book: false)).not_to be_allowed
      expect(reserve(t0 + 51.seconds)).to be_allowed
    end

    it "uses the gap and jitter an admin set" do
      AppSettings.set(:stats_min_gap_seconds, 120)
      AppSettings.set(:stats_gap_jitter_seconds, 0)
      reserve
      finish(ok)
      expect(session.reload.next_run_at).to eq(t0 + 120.seconds)
    end

    it "gives jobs that must wait their own times, a run apart, instead of one time for all" do
      reserve
      finish(ok)
      opens = session.reload.next_run_at
      first, second, third = Array.new(3) { reserve }
      expect([ first, second, third ].map(&:allowed?)).to all(be(false))
      expect(first.at).to eq(opens)
      expect(second.at - first.at).to be_within(0.001).of(60) # 30 s gap + 15 s jitter + 15 s for the run
      expect(third.at - second.at).to be_within(0.001).of(60)
      expect(described_class.next_free_at("spotify")).to eq(third.at + 60.seconds)
    end

    it "lets a platform with no session through (the helper won't be asked anything)" do
      expect(described_class.reserve("apple")).to be_allowed
      expect { described_class.finish("apple", ok) }.not_to raise_error
    end
  end

  describe "the hourly and daily caps" do
    it "allows 40 runs in any hour, then waits until the oldest is an hour old" do
      times = Array.new(40) { |i| t0 - 59.minutes + i.minutes }
      ran_at(*times)
      slot = reserve
      expect(slot).not_to be_allowed
      expect(slot.at).to eq(times.first + 1.hour)
      expect(reserve(times.first + 1.hour + 1.second)).to be_allowed
    end

    it "allows 300 runs in any 24 hours" do
      times = Array.new(300) { |i| t0 - 23.hours + (i * 4).minutes } # 15 an hour, under the hourly cap
      ran_at(*times)
      expect(reserve(book: false)).to have_attributes(allowed?: false, at: times.first + 1.day)
    end

    it "reads the caps from the settings" do
      AppSettings.set(:stats_runs_per_hour, 2)
      ran_at(t0 - 30.minutes, t0 - 10.minutes)
      expect(reserve(book: false)).to have_attributes(allowed?: false, at: t0 + 30.minutes)
    end

    it "forgets runs older than a day" do
      ran_at(*Array.new(300) { |i| t0 - 2.days + i.minutes })
      expect(reserve).to be_allowed
      expect(session.reload.run_log).to eq([ t0.to_i ])
    end
  end

  describe "a rate-limited answer" do
    def rate_limited(retry_after = nil) = fetch_error("rate_limited", "Spotify answered 429.", retry_after: retry_after)

    it "cools the platform down for an hour, doubling while it repeats, up to a day" do
      waits = Array.new(7) do
        finish(rate_limited)
        (session.reload.cooldown_until - t0).to_i
      end
      expect(waits).to eq([ 1, 2, 4, 8, 16, 24, 24 ].map { |hours| hours.hours.to_i })
      expect(session).to have_attributes(rate_limits_in_a_row: 7, last_rate_limited_at: t0)
      expect(reserve(t0 + 23.hours, book: false)).to have_attributes(allowed?: false, at: t0 + 24.hours)
    end

    it "waits what the platform asked, doubling from there, and never less than it asked" do
      finish(rate_limited(120))
      expect(session.reload.cooldown_until).to eq(t0 + 120.seconds)
      finish(rate_limited(120))
      expect(session.reload.cooldown_until).to eq(t0 + 240.seconds)
      finish(rate_limited(3.days.to_i))
      expect(session.reload.cooldown_until).to eq(t0 + 3.days)
    end

    it "starts the doubling again after a run that works" do
      2.times { finish(rate_limited) }
      finish(ok)
      expect(session.reload.rate_limits_in_a_row).to eq(0)
      finish(rate_limited)
      expect(session.reload.cooldown_until).to eq(t0 + 1.hour)
    end

    it "hands out a time after the cooldown for a sync to come back" do
      finish(rate_limited(600))
      expect(described_class.later("spotify")).to be >= t0 + 600.seconds
    end
  end

  describe "failed runs in a row" do
    it "pauses an hour after 5, and again after each more, until a run works" do
      4.times { finish(fetch_error("failed")) }
      expect(session.reload.next_run_at).to be < t0 + 1.minute
      finish(fetch_error("expired"))
      expect(session.reload).to have_attributes(failures_in_a_row: 5, next_run_at: t0 + 1.hour)
      expect(described_class.status(session.reload)).to have_attributes(paused: true, next_run_at: t0 + 1.hour)

      finish(fetch_error("failed"), t0 + 1.hour)
      expect(session.reload.next_run_at).to eq(t0 + 2.hours)

      finish(ok, t0 + 2.hours)
      expect(session.reload.failures_in_a_row).to eq(0)
    end

    it "doesn't count an answer about one connection (no access, no such show)" do
      4.times { finish(fetch_error("failed")) }
      finish(fetch_error("forbidden"))
      finish(fetch_error("not_found"))
      expect(session.reload.failures_in_a_row).to eq(4)
    end
  end

  describe ".track" do
    it "records how the run went and returns its result" do
      expect(described_class.track("spotify") { ok }).to eq(ok)
      expect(session.reload.failures_in_a_row).to eq(0)
    end

    it "records a run that blew up as failed, and lets the error through" do
      expect { described_class.track("spotify") { raise IOError, "boom" } }.to raise_error(IOError)
      expect(session.reload.failures_in_a_row).to eq(1)
    end
  end

  describe ".room" do
    it "is how many runs fit before the next pass, within what the hour leaves" do
      expect(described_class.room("spotify", within: 15.minutes)).to eq(16) # every 60 s, from now
      AppSettings.set(:stats_runs_per_hour, 5)
      ran_at(t0 - 30.minutes, t0 - 20.minutes)
      expect(described_class.room("spotify", within: 15.minutes)).to eq(3)
    end

    it "counts only the slots after the jobs already waiting" do
      expect(reserve).to be_allowed # one runs (for up to 75 s, then 30 to 45 s)
      8.times { reserve } # 8 wait, a minute apart, until about 10 minutes from now
      expect(described_class.room("spotify", within: 15.minutes)).to eq(6)
      6.times { reserve }
      expect(described_class.room("spotify", within: 15.minutes)).to eq(0)
    end

    it "is 0 while the platform stays shut past the next pass, or without a session" do
      session.update_columns(cooldown_until: t0 + 2.hours)
      expect(described_class.room("spotify", within: 15.minutes)).to eq(0)
      expect(described_class.room("apple", within: 15.minutes)).to eq(0)
    end
  end

  it "reports the platform's state for the admin page" do
    ran_at(t0 - 2.hours, t0 - 30.minutes, t0 - 5.minutes)
    session.update_columns(failures_in_a_row: 2, last_rate_limited_at: t0 - 1.day, cooldown_until: t0 - 1.hour)
    status = described_class.status(session.reload)
    expect(status).to have_attributes(runs_this_hour: 2, runs_today: 3, next_run_at: t0, cooldown_until: nil,
                                      failures_in_a_row: 2, last_rate_limited_at: t0 - 1.day, paused: false)
    expect(status.limits.per_hour).to eq(40)
  end
end
