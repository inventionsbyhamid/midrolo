class CreateSpendEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :spend_entries do |t|
      t.references :user, foreign_key: true
      # report_id and pitch_id are plain bigints for now: the FKs are added with the reports (Task 9) and pitches (Task 14) tables.
      t.bigint :report_id
      t.bigint :pitch_id
      t.string :kind, null: false, default: "llm"
      t.string :bucket, null: false
      t.string :model
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.integer :cache_read_tokens, null: false, default: 0
      t.integer :cache_write_tokens, null: false, default: 0
      t.decimal :cost_usd, precision: 10, scale: 5, null: false, default: 0
      t.datetime :created_at, null: false
    end
    add_index :spend_entries, :report_id
    add_index :spend_entries, :pitch_id
    add_index :spend_entries, [ :bucket, :created_at ]
  end
end
