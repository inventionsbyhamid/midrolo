# The time of the newest provider event applied to a subscription, so a late event can't undo a newer one
# (Billing::Sync, Review Focus #5).
class AddLastEventAtToSubscriptions < ActiveRecord::Migration[8.1]
  def change
    add_column :subscriptions, :last_event_at, :datetime
  end
end
