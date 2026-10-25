# Re-enqueues billing webhooks left unprocessed (spec §9a): one whose job was never enqueued (a crash between storing
# it and enqueueing) or failed for good after its retries. Runs on a schedule (config/recurring.yml). Each run takes
# at most BATCH events not touched for STRANDED_AFTER, least recently tried first, and touches them, so one event that
# keeps failing can't crowd out the rest. ProcessBillingEventJob is idempotent, so a spare run costs nothing.
class RequeueStrandedBillingEventsJob < ApplicationJob
  queue_as :default

  STRANDED_AFTER = 10.minutes
  BATCH = 50

  def perform
    stranded = BillingEvent.where(processed_at: nil).where(updated_at: ..STRANDED_AFTER.ago).order(:updated_at, :id)
                           .limit(BATCH).to_a
    stranded.each do |billing_event|
      billing_event.touch
      ProcessBillingEventJob.perform_later(billing_event.id)
    end
    Rails.logger.info("[Billing] re-enqueued #{stranded.size} stranded billing events") if stranded.any?
  end
end
