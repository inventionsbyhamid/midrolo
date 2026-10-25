# The provider payment ids applied to a subscription (a Sponsor Sprint's one-time payments), so a payment delivered
# again under a new webhook id doesn't extend the sprint twice (Billing::Sync).
class AddPaymentIdsToSubscriptions < ActiveRecord::Migration[8.1]
  def change
    add_column :subscriptions, :payment_ids, :string, array: true, null: false, default: []
  end
end
