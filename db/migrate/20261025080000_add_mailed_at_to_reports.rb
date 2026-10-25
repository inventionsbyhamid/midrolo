# When a full report's outcome mail went (ReportMailJob, R113): each is claimed with a conditional update before it is
# delivered, so a job run twice sends it once.
class AddMailedAtToReports < ActiveRecord::Migration[8.1]
  def change
    add_column :reports, :ready_mailed_at, :datetime
    add_column :reports, :needs_input_mailed_at, :datetime
  end
end
