# The marketplace catalog (plan/2026-10-29-marketplace-build-spec.md, section 3). Stored pictures, artwork first: one
# row per distinct file (sha256), the file and its webp variants in Active Storage (Image).
class CreateImages < ActiveRecord::Migration[8.1]
  def change
    # Trigram search on podcast titles (CreatePodcasts) needs it.
    enable_extension "pg_trgm"

    create_table :images do |t|
      t.string :sha256, null: false
      t.string :source_url
      t.integer :width
      t.integer :height
      t.string :content_type
      t.datetime :suppressed_at
      t.timestamps
    end
    add_index :images, :sha256, unique: true
  end
end
