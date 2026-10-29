# "Remove this page": requests to take a podcast down, and the podcasts and images kept out of the catalog for good
# (by podcast guid, feed URL digest or image sha256), so a re-seed or a search can't bring them back.
class CreateRemovalRequestsAndSuppressions < ActiveRecord::Migration[8.1]
  def change
    create_table :removal_requests do |t|
      t.references :podcast, null: false, foreign_key: true
      t.string :email
      t.text :reason
      t.string :status, null: false, default: "pending" # pending, approved, rejected
      t.timestamps
    end
    add_index :removal_requests, :status

    create_table :suppressions do |t|
      t.string :kind, null: false # podcast, image
      t.string :value, null: false
      t.string :reason
      t.timestamps
    end
    add_index :suppressions, %i[kind value], unique: true
  end
end
