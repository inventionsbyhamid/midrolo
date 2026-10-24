class CreateReports < ActiveRecord::Migration[8.1]
  def change
    create_table :reports do |t|
      t.references :show, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :status, null: false, default: "queued"
      t.string :profile_kind
      t.jsonb :seeds
      t.jsonb :audience
      t.jsonb :demographics
      t.jsonb :heatmap
      t.text :summary
      t.string :error_message
      t.datetime :started_at
      t.datetime :finished_at
      t.decimal :cost_usd, precision: 10, scale: 5, default: 0, null: false
      t.integer :taste_calls, default: 0, null: false
      t.string :spend_bucket
      t.string :sample_slug
      t.timestamps
    end
    add_index :reports, :sample_slug, unique: true, where: "sample_slug IS NOT NULL"
    # Only one active (queued or running) report per show, even under a race.
    add_index :reports, :show_id, unique: true, where: "status IN ('queued', 'running')", name: "index_reports_one_active_per_show"
    add_foreign_key :spend_entries, :reports, on_delete: :nullify

    create_table :agent_steps do |t|
      t.references :report, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.string :tool
      t.string :label, null: false
      t.string :status, null: false, default: "running"
      t.text :input_summary
      t.text :output_summary
      t.integer :duration_ms
      t.timestamps
    end

    create_table :sponsor_matches do |t|
      t.references :report, null: false, foreign_key: true
      t.references :show, null: false, foreign_key: true
      t.string :brand_entity_id, null: false
      t.string :name
      t.string :image_url
      t.string :website
      t.string :category
      t.string :reason
      t.float :affinity
      t.float :popularity
      t.integer :fit_score
      t.string :tier
      t.jsonb :evidence, null: false, default: {}
      t.string :status, null: false, default: "suggested"
      t.text :notes
      t.date :follow_up_on
      t.integer :position
      t.timestamps
    end
    add_index :sponsor_matches, %i[report_id brand_entity_id], unique: true
  end
end
