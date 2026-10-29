# A podcast's feed URL moving for good (Catalog::Ingest: a chain of permanent redirects, or itunes:new-feed-url), kept
# for the record with the owner show whose claim the move released: an owner proved control of the old feed, not the
# new one (code review H1).
class CreatePodcastFeedMoves < ActiveRecord::Migration[8.1]
  def change
    create_table :podcast_feed_moves do |t|
      t.references :podcast, null: false, foreign_key: { on_delete: :cascade }
      t.string :from_url, null: false
      t.string :to_url, null: false
      t.string :via, null: false # redirect, new_feed_url
      t.references :released_show, foreign_key: { to_table: :shows, on_delete: :nullify }
      t.timestamps
    end
  end
end
