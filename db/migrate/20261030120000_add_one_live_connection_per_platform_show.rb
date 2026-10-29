# One platform show (a Spotify or Apple show id) backs one Midrolo page: every connection but a disconnected one holds
# it (StatConnection validates the same with a friendly message), so a same-named clone can't point at a real show's
# id while that show's connection exists in any state. approved_at records an admin's check of a connection whose show
# matched by name only while another catalog podcast has that name (Stats::Ownership). Plus the sponsors sweep's
# lookup: episodes not yet scanned, by podcast.
class AddOneLiveConnectionPerPlatformShow < ActiveRecord::Migration[8.1]
  def change
    add_column :stat_connections, :approved_at, :datetime
    add_index :stat_connections, %i[provider external_id], unique: true, where: "status <> 'disconnected'",
                                                           name: "index_stat_connections_one_per_platform_show"
    add_index :episodes, :podcast_id, where: "sponsor_scanned_at IS NULL", name: "index_episodes_unscanned_on_podcast_id"
  end
end
