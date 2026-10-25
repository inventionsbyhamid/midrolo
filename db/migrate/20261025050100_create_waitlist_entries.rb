# The founding-member waitlist (spec §11): who asked to buy which price key while billing is in waitlist mode, once
# per email and key, whatever the email's case (the database enforces it on lower(email); the model also stores
# emails downcased). A signed-in entry belongs to its user and goes with the account.
class CreateWaitlistEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :waitlist_entries do |t|
      t.string :email, null: false
      t.string :price_key, null: false
      t.references :user, foreign_key: true
      t.timestamps
    end
    add_index :waitlist_entries, "lower(email), price_key", unique: true,
                                                            name: "index_waitlist_entries_on_lower_email_and_price_key"
  end
end
