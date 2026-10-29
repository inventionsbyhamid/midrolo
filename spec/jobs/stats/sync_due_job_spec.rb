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

  it "enqueues nothing while no session works" do
    create(:service_session, platform: "spotify", status: "expired")
    connection("pending_invite")
    described_class.perform_now(now)
    expect(enqueued_ids).to be_empty
  end
end
