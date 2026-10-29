# A podcast's earlier slugs, so an old link (a renamed show, a /k/:slug kit link) 301s to its page.
class CreatePodcastRedirects < ActiveRecord::Migration[8.1]
  def change
    create_table :podcast_redirects do |t|
      t.string :from_slug, null: false
      t.references :podcast, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :podcast_redirects, :from_slug, unique: true
  end
end
