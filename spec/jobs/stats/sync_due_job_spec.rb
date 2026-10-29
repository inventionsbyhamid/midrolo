require "rails_helper"

RSpec.describe Stats::SyncDueJob do
  include ActiveJob::TestHelper

  let(:now) { Time.current }

  def connection(status, provider: "spotify", **attributes)
    create(:stat_connection, provider: provider, status: status, **attributes)
  end

  def enqueued_ids = enqueued_jobs.select { |job| job["job_class"] == "Stats::SyncJob" }.map { |job| job["arguments"].first }

  it "enqueues what is due, on platforms with a working session" do
    create(:service_session, platform: "spotify")
    due = [
      connection("pending_invite"),
      connection("active", last_synced_at: 2.days.ago),
      connection("active", last_synced_at: nil),
      connection("failed", activated_at: 5.days.ago, last_checked_at: 2.days.ago),
      connection("mismatch", activated_at: nil, last_checked_at: 2.days.ago),
      connection("mismatch", activated_at: 30.days.ago, created_at: 30.days.ago, last_checked_at: nil)
    ]
    not_due = [
      connection("active", last_synced_at: 2.hours.ago),
      connection("active", last_synced_at: 2.days.ago, last_checked_at: 10.minutes.ago), # failing: retried hourly
      connection("failed", activated_at: nil), # an invite that lapsed waits for the owner
      connection("failed", activated_at: 5.days.ago, last_checked_at: 2.hours.ago),
      connection("mismatch", activated_at: nil, created_at: 20.days.ago),
      connection("disconnected"),
      connection("pending_invite", provider: "apple") # no Apple session
    ]

    described_class.perform_now(now)

    expect(enqueued_ids).to match_array(due.map(&:id))
    expect(enqueued_ids & not_due.map(&:id)).to be_empty
  end

  # Code review M6: invites nobody accepted mustn't run the helper against the platforms every 15 minutes for 14 days.
  it "polls a pending invite every run for 2 hours, hourly until a day old, then every 6 hours" do
    create(:service_session, platform: "spotify")
    due = [
      connection("pending_invite", created_at: 30.minutes.ago, last_checked_at: 14.minutes.ago),
      connection("pending_invite", created_at: 5.hours.ago, last_checked_at: 61.minutes.ago),
      connection("pending_invite", created_at: 5.hours.ago, last_checked_at: 57.minutes.ago), # a run lands a bit late
      connection("pending_invite", created_at: 5.hours.ago, last_checked_at: nil),
      connection("pending_invite", created_at: 3.days.ago, last_checked_at: 7.hours.ago),
      connection("pending_invite", created_at: 15.days.ago, last_checked_at: 7.hours.ago) # SyncJob lapses it
    ]
    not_due = [
      connection("pending_invite", created_at: 5.hours.ago, last_checked_at: 20.minutes.ago),
      connection("pending_invite", created_at: 3.days.ago, last_checked_at: 2.hours.ago),
      connection("pending_invite", created_at: 10.days.ago, last_checked_at: 5.hours.ago)
    ]

    described_class.perform_now(now)

    expect(enqueued_ids).to match_array(due.map(&:id))
    expect(enqueued_ids & not_due.map(&:id)).to be_empty
  end

  describe "spreading the daily syncs" do
    let(:now) { Time.utc(2026, 10, 30, 12, 0) }

    around { |example| travel_to(now) { example.run } }

    # A connection whose daily minute is hh:mm UTC (ids chosen far above the table's sequence).
    def at_minute(hour, minute, **attributes)
      @taken ||= []
      id = (1_000_000..).find { |candidate| described_class.daily_minute(candidate) == (hour * 60) + minute && @taken.exclude?(candidate) }
      @taken << id
      connection("active", id: id, **attributes)
    end

    it "gives every minute of the day to one id in 1440, and spreads consecutive ids over the day's runs" do
      expect((1..1440).map { |id| described_class.daily_minute(id) }.uniq.size).to eq(1440)
      runs = (1..96).map { |id| described_class.daily_minute(id) / 15 }.tally
      expect(runs.size).to be > 80
      expect(runs.values.max).to be <= 2
    end

    it "syncs each active connection once a day at its own minute, not all in one run" do
      create(:service_session, platform: "spotify")
      due = [
        at_minute(11, 30, last_synced_at: Time.utc(2026, 10, 29, 11, 40)), # its 11:30 came today
        at_minute(13, 0, last_synced_at: Time.utc(2026, 10, 29, 12, 50)) # its 13:00 came yesterday, after it synced
      ]
      not_due = [
        at_minute(13, 0, last_synced_at: Time.utc(2026, 10, 29, 13, 10)), # 22 hours ago, but its 13:00 hasn't come since
        at_minute(11, 30, last_synced_at: Time.utc(2026, 10, 30, 11, 35)), # done today
        at_minute(2, 0, last_synced_at: Time.utc(2026, 10, 30, 1, 0)) # its 02:00 came, but it synced 11 hours ago
      ]

      described_class.perform_now(now)

      expect(enqueued_ids).to match_array(due.map(&:id))
      expect(enqueued_ids & not_due.map(&:id)).to be_empty
    end
  end

  describe "the throttle" do
    before { create(:service_session, platform: "spotify") }

    it "enqueues nothing for a platform cooling down past the next run" do
      ServiceSession.find_by!(platform: "spotify").update_columns(cooldown_until: 2.hours.from_now)
      connection("pending_invite")
      described_class.perform_now(now)
      expect(enqueued_ids).to be_empty
    end

    it "enqueues no more than can run before the next pass, people waiting first" do
      AppSettings.set(:stats_runs_per_hour, 3)
      ServiceSession.find_by!(platform: "spotify").update_columns(run_log: [ 10.minutes.ago.to_i ])
      oldest = connection("active", last_synced_at: 3.days.ago, last_checked_at: 3.days.ago)
      connection("active", last_synced_at: 2.days.ago, last_checked_at: 2.days.ago)
      invite = connection("pending_invite")

      described_class.perform_now(now)

      expect(enqueued_ids).to eq([ invite.id, oldest.id ]) # 3 an hour, 1 already used
    end
  end

  it "enqueues nothing while no session works" do
    create(:service_session, platform: "spotify", status: "expired")
    connection("pending_invite")
    described_class.perform_now(now)
    expect(enqueued_ids).to be_empty
  end
end
