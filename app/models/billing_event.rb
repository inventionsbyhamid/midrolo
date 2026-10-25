# One billing provider webhook, stored once by (provider, event_id) before it is processed (spec §9a, §10), so a
# replayed or retried delivery is processed only once. ProcessBillingEventJob applies it and sets processed_at;
# error_message says why it changed nothing, when it didn't. event_type is the provider's own event name.
class BillingEvent < ApplicationRecord
  validates :provider, :event_id, presence: true

  # The row for a verified Billing::Event: the one already stored for its provider and id, else a new one.
  def self.record!(event)
    create_or_find_by!(provider: event.provider, event_id: event.id) do |row|
      row.event_type = event.name
      row.payload = event.raw
    end
  end

  def processed? = processed_at.present?

  def mark_processed!(error_message = nil)
    update!(processed_at: Time.current, error_message: error_message)
  end
end
