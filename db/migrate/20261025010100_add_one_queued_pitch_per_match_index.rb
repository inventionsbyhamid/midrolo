class AddOneQueuedPitchPerMatchIndex < ActiveRecord::Migration[8.1]
  def change
    # R53: two requests racing on one match can't both start a pitch.
    add_index :pitches, :sponsor_match_id, unique: true, where: "status = 'queued'", name: "index_pitches_one_queued_per_match"
  end
end
