# When a notify list entry was told that new runs are back (R81), so each one is emailed once per pause.
class AddNotifiedAtToWaitlistEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :waitlist_entries, :notified_at, :datetime
  end
end
