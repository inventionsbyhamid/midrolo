class CreateShows < ActiveRecord::Migration[8.1]
  def change
    create_table :shows do |t|
      t.references :user, null: false, foreign_key: true
      t.string :directory_id
      t.string :itunes_id
      t.string :feed_url
      t.string :title, null: false
      t.string :author
      t.text :description
      t.string :artwork_url
      t.jsonb :categories, null: false, default: []
      t.integer :episode_count
      t.string :language
      t.integer :cadence_days
      t.integer :downloads_per_episode
      t.string :country, null: false, default: "US"
      t.string :contact_email
      t.jsonb :hints, null: false, default: { "comparable_shows" => [], "topics" => [] }
      t.string :owner_email
      t.datetime :verified_at
      t.string :slug # set only on verification (Task 15)
      t.string :qloo_entity_id

      t.timestamps
    end

    add_index :shows, :slug, unique: true
    add_index :shows, %i[user_id directory_id], unique: true, where: "directory_id IS NOT NULL"
    add_index :shows, %i[user_id feed_url], unique: true, where: "feed_url IS NOT NULL"
  end
end
