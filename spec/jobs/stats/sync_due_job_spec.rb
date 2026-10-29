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

  it "enqueues nothing while no session works" do
    create(:service_session, platform: "spotify", status: "expired")
    connection("pending_invite")
    described_class.perform_now(now)
    expect(enqueued_ids).to be_empty
  end
end
