class CreatePitches < ActiveRecord::Migration[8.1]
  def change
    create_table :pitches do |t|
      # Cascade: a re-saved match list deletes its matches with delete_all, which skips callbacks.
      t.references :sponsor_match, null: false, foreign_key: { on_delete: :cascade }
      t.string :status, null: false, default: "queued"
      t.string :subject
      t.text :body
      t.jsonb :angles, null: false, default: []
      t.text :offer
      t.text :follow_up
      t.string :contact_role
      t.string :model
      t.decimal :cost_usd, precision: 10, scale: 5, null: false, default: 0
      t.string :error_message
      t.timestamps
    end
  end
end
