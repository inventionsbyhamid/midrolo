# Paid plans from a billing provider (spec §10, R60). Task 17 writes the rows from checkout and webhooks; Entitlements
# reads them. Sprint is a one-off payment stored as plan "sprint" with a 30-day period.
class CreateSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :subscriptions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :provider_customer_id
      t.string :provider_subscription_id
      t.string :price_key
      t.string :plan, null: false
      t.string :status, null: false
      t.datetime :current_period_start
      t.datetime :current_period_end
      t.boolean :cancel_at_period_end, null: false, default: false
      t.timestamps
    end
    add_index :subscriptions, %i[provider provider_subscription_id], unique: true,
                                                                     where: "provider_subscription_id IS NOT NULL"
  end
end
