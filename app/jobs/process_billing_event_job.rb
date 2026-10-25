# Applies one stored billing webhook (BillingEvent) to our subscriptions through Billing::Sync, then marks it
# processed, with Sync's note when it changed nothing. Idempotent: the event's row is locked and an event already
# processed is skipped, so a replayed or doubly enqueued webhook applies once.
#
# Transient database contention (a deadlock, two first events racing to create one subscription) runs again shortly.
# A cancellation or failed payment that beats its subscription's start event waits for it, then gives up with a note.
class ProcessBillingEventJob < ApplicationJob
  queue_as :default

  retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, ActiveRecord::RecordNotUnique,
           wait: 5.seconds, attempts: 5
  retry_on Billing::Sync::UnknownSubscription, wait: :polynomially_longer, attempts: 6 do |job, error|
    Rails.logger.warn("[Billing] #{error.message}; marking billing event #{job.arguments.first} processed")
    BillingEvent.find_by(id: job.arguments.first)&.mark_processed!(error.message)
  end

  def perform(billing_event_id)
    billing_event = BillingEvent.find_by(id: billing_event_id)
    return unless billing_event

    billing_event.with_lock do
      next if billing_event.processed?

      provider = Billing::Provider.for(billing_event.provider)
      raise ArgumentError, "no billing provider #{billing_event.provider.inspect} here" unless provider

      event = provider.parse(billing_event.payload.to_json, id: billing_event.event_id)
      billing_event.mark_processed!(Billing::Sync.apply(event))
    end
  end
end
