# Promo usage derives from the user's done promo-bucket agent reports (R59), so the counter goes.
class RemovePromoReportsUsedFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :promo_reports_used, :integer, default: 0, null: false
  end
end
