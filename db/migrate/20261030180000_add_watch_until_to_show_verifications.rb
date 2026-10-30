# After a failed "Check my feed", Verifications::WatchFeedJob keeps reading the feed until watch_until (30 minutes
# after the latest failed press). Null when no watch runs.
class AddWatchUntilToShowVerifications < ActiveRecord::Migration[8.1]
  def change
    add_column :show_verifications, :watch_until, :datetime
  end
end
