require "rails_helper"

RSpec.describe RequeueStrandedBillingEventsJob do
  include ActiveJob::TestHelper

  def billing_event(age, processed: false)
    BillingEvent.create!(provider: "dodo", event_id: "msg_#{SecureRandom.hex(4)}", payload: {},
                         created_at: age.ago, updated_at: age.ago, processed_at: (Time.current if processed))
  end

  it "re-enqueues unprocessed events left for over 10 minutes, and touches them" do
    stranded = billing_event(11.minutes)
    billing_event(5.minutes) # its job may still be on its way
    billing_event(1.hour, processed: true)

    expect { described_class.perform_now }.to have_enqueued_job(ProcessBillingEventJob).with(stranded.id).exactly(:once)
    expect(stranded.reload.updated_at).to be_within(1.second).of(Time.current)
  end

  it "takes at most BATCH a run, least recently tried first, so a failing event can't crowd out the rest" do
    stub_const("#{described_class}::BATCH", 2)
    oldest = billing_event(3.hours)
    middle = billing_event(2.hours)
    newest = billing_event(1.hour)

    described_class.perform_now
    expect(enqueued_jobs.map { |job| job["arguments"].first }).to eq([ oldest.id, middle.id ])

    clear_enqueued_jobs
    travel 11.minutes
    described_class.perform_now
    expect(enqueued_jobs.map { |job| job["arguments"].first }).to eq([ newest.id, oldest.id ])
  end
end
