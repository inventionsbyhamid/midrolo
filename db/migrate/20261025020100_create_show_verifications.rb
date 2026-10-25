class CreateShowVerifications < ActiveRecord::Migration[8.1]
  def change
    # One row per code sent or token issued. "kind" rather than the plan's "method", which would shadow Object#method.
    create_table :show_verifications do |t|
      t.references :show, null: false, foreign_key: true, index: false
      t.string :kind, null: false # email | feed_token
      t.string :code_digest # HMAC-SHA256 of the emailed code; the code itself is never stored
      t.string :token
      t.string :sent_to
      t.integer :attempts, null: false, default: 0
      t.datetime :expires_at, null: false
      t.datetime :verified_at
      t.timestamps
    end

    add_index :show_verifications, %i[show_id created_at]
  end
end
