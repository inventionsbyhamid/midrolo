# The brand side: a fit search (the agent run that finds podcasts for a brand), its scored results, and the podcasts a
# brand saved. A search is its user's and goes with their account; a saved podcast stays on the brand's list.
class CreateFitSearches < ActiveRecord::Migration[8.1]
  def change
    create_table :fit_searches do |t|
      t.string :public_id, null: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :brand, foreign_key: true
      t.string :query, null: false
      t.string :website
      t.jsonb :categories, null: false, default: []
      t.integer :budget_cents
      t.string :status, null: false, default: "queued" # queued, running, done, failed
      t.string :qloo_brand_entity_id
      t.text :summary
      t.string :error_message
      t.integer :taste_calls, null: false, default: 0
      t.decimal :cost_usd, precision: 10, scale: 5, null: false, default: 0
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :fit_searches, :public_id, unique: true
    add_index :fit_searches, %i[user_id created_at]

    create_table :fit_results do |t|
      t.references :fit_search, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :podcast, null: false, foreign_key: true
      t.integer :position
      t.integer :score # 0 to 100
      t.float :taste_score
      t.jsonb :reasons, null: false, default: []
      t.jsonb :proof, null: false, default: {}
      t.string :price_fit
      t.timestamps
    end
    add_index :fit_results, %i[fit_search_id podcast_id], unique: true

    create_table :saved_podcasts do |t|
      t.references :brand, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :podcast, null: false, foreign_key: true
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :note
      t.timestamps
    end
    add_index :saved_podcasts, %i[brand_id podcast_id], unique: true

    # A fit search's LLM spend (the summary), as reports and pitches have theirs.
    add_reference :spend_entries, :fit_search, foreign_key: { on_delete: :nullify }
  end
end
