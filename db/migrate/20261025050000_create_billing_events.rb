# The webhook log for any billing provider (spec §10): each event is stored once by (provider, event_id), then
# ProcessBillingEventJob applies it and sets processed_at. error_message notes why an event changed nothing.
class CreateBillingEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :billing_events do |t|
      t.string :provider, null: false
      t.string :event_id, null: false
      t.string :event_type
      t.jsonb :payload, null: false, default: {}
      t.datetime :processed_at
      t.string :error_message
      t.timestamps
    end
    add_index :billing_events, %i[provider event_id], unique: true
  end
end
