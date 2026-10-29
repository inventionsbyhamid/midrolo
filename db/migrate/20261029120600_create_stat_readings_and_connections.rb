# Verified stats (build spec section 11): each number with its source and trust level, the connections that read
# them from the platform itself (a podcaster invites Midrolo's service account to their Spotify or Apple analytics),
# and the service accounts' own sessions, which an admin enters.
class CreateStatReadingsAndConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :stat_readings do |t|
      t.references :podcast, null: false, foreign_key: true, index: false
      t.string :metric, null: false
      t.bigint :value, null: false
      t.string :source, null: false
      t.string :trust, null: false # feed, public, provided, verified
      t.integer :period_days
      t.datetime :captured_at, null: false
      t.datetime :expires_at
      t.jsonb :evidence, null: false, default: {}
      t.jsonb :breakdown, null: false, default: {} # audience splits: age, gender, country
      t.timestamps
    end
    add_index :stat_readings, %i[podcast_id metric source], unique: true
    add_index :stat_readings, :expires_at

    create_table :stat_connections do |t|
      t.references :podcast, null: false, foreign_key: true, index: false
      # The workspace it was made from, and who made it (a reading counts only while they hold the claim).
      t.references :show, foreign_key: { on_delete: :nullify }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :provider, null: false # spotify, apple, and the later connectors
      t.string :external_id # the show's id on the platform
      t.text :credentials # encrypted (StatConnection encrypts :credentials); generic, connectors decide the shape
      t.string :status, null: false, default: "pending_invite" # pending_invite, active, mismatch, failed, disconnected
      t.datetime :last_checked_at
      t.datetime :activated_at
      t.datetime :last_synced_at
      t.string :last_error
      t.datetime :file_checked_at # an admin checked an uploaded export or screenshot
      t.timestamps
    end
    add_index :stat_connections, %i[podcast_id provider], unique: true
    add_index :stat_connections, :status

    # Midrolo's own service accounts' sessions on each platform, one per platform.
    create_table :service_sessions do |t|
      t.string :platform, null: false # spotify, apple
      t.text :credentials # encrypted (ServiceSession encrypts :credentials)
      t.string :status, null: false, default: "ok" # ok, expired
      t.datetime :last_ok_at
      t.string :last_error
      t.datetime :expires_hint
      t.timestamps
    end
    add_index :service_sessions, :platform, unique: true
  end
end
