# When the owner last opened a finished report (ReportsController#show), so the report ready mail is skipped for a
# report they already saw (Task 20).
class AddViewedAtToReports < ActiveRecord::Migration[8.1]
  def change
    add_column :reports, :viewed_at, :datetime
  end
end
