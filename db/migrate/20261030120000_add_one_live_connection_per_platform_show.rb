# One platform show (a Spotify or Apple show id) can count for one Midrolo page at a time: a pending invite or an active
# connection holds it (StatConnection validates the same with a friendly message). Mismatched, failed and disconnected
# rows keep their history and hold nothing. Plus the sponsors sweep's lookup: episodes not yet scanned, by podcast.
class AddOneLiveConnectionPerPlatformShow < ActiveRecord::Migration[8.1]
  LIVE = "status IN ('pending_invite', 'active')".freeze

  def change
    add_index :stat_connections, %i[provider external_id], unique: true, where: LIVE,
                                                           name: "index_stat_connections_one_live_per_platform_show"
    add_index :episodes, :podcast_id, where: "sponsor_scanned_at IS NULL", name: "index_episodes_unscanned_on_podcast_id"
  end
end
