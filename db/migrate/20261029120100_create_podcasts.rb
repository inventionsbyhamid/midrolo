# The canonical public record of a podcast: one row per real show, whoever added it (spec section 3). A user's Show
# becomes their workspace for one of these (MoveShowPodcastFieldsToPodcasts).
class CreatePodcasts < ActiveRecord::Migration[8.1]
  SEARCHABLE = "setweight(to_tsvector('simple', coalesce(title, '')), 'A') || " \
               "setweight(to_tsvector('simple', coalesce(author, '')), 'B') || " \
               "setweight(to_tsvector('english', coalesce(description, '')), 'C')".freeze

  def change
    create_table :podcasts do |t|
      t.string :public_id, null: false
      t.string :slug, null: false
      t.string :title, null: false
      t.string :title_key # Research::Names.normalize(title), for matching names from Qloo and the directory
      t.string :author
      t.text :description
      t.string :language
      t.boolean :explicit, null: false, default: false
      t.string :itunes_type
      t.jsonb :categories, null: false, default: []
      t.string :feed_url, null: false
      t.string :website
      t.bigint :apple_id
      t.bigint :podcast_index_id
      t.string :podcast_guid
      t.string :qloo_entity_id
      t.float :qloo_popularity
      t.string :owner_email # encrypted (Podcast encrypts :owner_email)
      t.string :artwork_url # the feed's artwork source, never rendered directly
      t.references :artwork_image, foreign_key: { to_table: :images, on_delete: :nullify }
      t.string :hosting_provider
      t.jsonb :measurement, null: false, default: []
      t.string :op3_show_uuid
      t.integer :episode_count, null: false, default: 0
      t.datetime :first_published_at
      t.datetime :last_published_at
      t.integer :cadence_days
      t.string :status, null: false, default: "pending"
      t.boolean :indexable, null: false, default: false
      t.string :source, null: false
      t.boolean :open_to_sponsors, null: false, default: false
      t.datetime :claimed_at
      t.integer :min_price_cents
      t.integer :downloads_per_episode
      t.string :downloads_trust
      t.string :feed_etag
      t.string :feed_last_modified
      t.string :feed_sha256
      t.datetime :feed_checked_at
      t.datetime :next_fetch_at
      t.datetime :leased_until # Catalog::RefreshDueJob's claim on a due podcast (FOR UPDATE SKIP LOCKED)
      t.integer :fetch_failures, null: false, default: 0
      t.string :last_error
      t.virtual :searchable, type: :tsvector, as: SEARCHABLE, stored: true
      t.timestamps
    end

    add_index :podcasts, :public_id, unique: true
    add_index :podcasts, :slug, unique: true
    add_index :podcasts, :feed_url, unique: true
    add_index :podcasts, :apple_id, unique: true
    add_index :podcasts, :podcast_index_id, unique: true
    add_index :podcasts, :podcast_guid, unique: true
    add_index :podcasts, :qloo_entity_id, unique: true
    add_index :podcasts, :categories, using: :gin
    add_index :podcasts, :searchable, using: :gin
    add_index :podcasts, :title, using: :gin, opclass: :gin_trgm_ops, name: "index_podcasts_on_title_trigram"
    # The directory's filters and sorts, and the refresh queue.
    add_index :podcasts, :status
    add_index :podcasts, :indexable
    add_index :podcasts, :open_to_sponsors
    add_index :podcasts, :claimed_at
    add_index :podcasts, :language
    add_index :podcasts, :min_price_cents
    add_index :podcasts, :downloads_per_episode
    add_index :podcasts, :downloads_trust
    add_index :podcasts, :last_published_at
    add_index :podcasts, :next_fetch_at
    add_index :podcasts, :leased_until
    add_index :podcasts, :title_key
  end
end
