# When a GeneratePitchJob run claimed the pitch (R135): a conditional update from nil, so a job delivered twice writes
# (and pays for) the pitch once. A transient error that retries gives the claim back for the next attempt.
class AddStartedAtToPitches < ActiveRecord::Migration[8.1]
  def change
    add_column :pitches, :started_at, :datetime
  end
end
