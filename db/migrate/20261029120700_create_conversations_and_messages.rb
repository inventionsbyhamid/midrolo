# Request a spot: a brand's conversation with a podcast's owner, its messages, and the brands a podcast has blocked.
# A user's account deletion keeps the other party's copy (user links are nullified).
class CreateConversationsAndMessages < ActiveRecord::Migration[8.1]
  OPEN = "status IN ('waiting_for_claim', 'open')".freeze

  def change
    create_table :conversations do |t|
      t.string :public_id, null: false
      t.references :podcast, null: false, foreign_key: true, index: true
      t.references :brand, null: false, foreign_key: true, index: false
      t.references :started_by, foreign_key: { to_table: :users, on_delete: :nullify }, index: false
      t.string :status, null: false # waiting_for_claim, open, accepted, declined, closed
      t.string :format
      t.jsonb :months, null: false, default: []
      t.integer :budget_cents
      t.datetime :last_message_at
      t.datetime :first_reply_at
      t.datetime :podcaster_read_at
      t.datetime :brand_read_at
      t.string :decline_reason
      t.datetime :closed_at
      t.datetime :reported_at
      t.timestamps
    end
    add_index :conversations, :public_id, unique: true
    add_index :conversations, %i[podcast_id brand_id], unique: true, where: OPEN, name: "index_conversations_one_open_per_pair"
    add_index :conversations, %i[started_by_id created_at]
    add_index :conversations, %i[brand_id last_message_at]

    create_table :messages do |t|
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, foreign_key: { on_delete: :nullify }
      t.text :body, null: false # at most 4000 characters
      t.timestamps
    end
    add_index :messages, %i[conversation_id created_at]

    create_table :blocks do |t|
      t.references :podcast, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :brand, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :blocks, %i[podcast_id brand_id], unique: true
  end
end
