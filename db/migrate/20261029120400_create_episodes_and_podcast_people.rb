# What a feed says about each podcast: its episodes (ingest upserts the newest 50 on every fetch and never deletes any
# in this slice) and the people it names (podcast:person, itunes:author).
class CreateEpisodesAndPodcastPeople < ActiveRecord::Migration[8.1]
  def change
    create_table :episodes do |t|
      t.references :podcast, null: false, foreign_key: true, index: false
      t.string :guid, null: false
      # title.parameterize.first(60) + "-" + 6 hex of SHA256(guid), set on insert only (Episode.slug_for).
      t.string :slug, null: false
      t.string :title, null: false
      t.text :description # plain text, at most 4000 characters
      t.datetime :published_at
      t.integer :duration_seconds
      t.string :episode_type
      t.integer :season
      t.integer :number
      t.string :enclosure_url
      t.string :link
      t.string :transcript_url
      t.datetime :sponsor_scanned_at
      t.timestamps
    end
    add_index :episodes, %i[podcast_id guid], unique: true
    add_index :episodes, %i[podcast_id slug], unique: true
    add_index :episodes, %i[podcast_id published_at], order: { published_at: :desc }

    create_table :podcast_people do |t|
      t.references :podcast, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.string :name_key, null: false
      t.string :role, null: false, default: "host" # host, guest, other
      t.string :href
      t.string :img_url
      t.references :image, foreign_key: { on_delete: :nullify }
      t.integer :episodes_count, null: false, default: 0
      t.timestamps
    end
    add_index :podcast_people, %i[podcast_id name_key role], unique: true
  end
end
