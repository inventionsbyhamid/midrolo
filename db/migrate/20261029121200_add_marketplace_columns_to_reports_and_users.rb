# Reports keep the shows Qloo finds similar ([{qloo_entity_id, name, score, podcast_id}]); users remember which side
# they last used (podcaster or brand), so sign in lands on the right dashboard.
class AddMarketplaceColumnsToReportsAndUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :reports, :similar_podcasts, :jsonb, null: false, default: []
    add_column :users, :last_role, :string
  end
end
