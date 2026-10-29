# Agent steps belong to a run: a Report, or a brand's FitSearch, which logs through the same Research::StepLogger and
# trace UI. Existing steps become the reports' (run_type 'Report').
class MakeAgentStepsPolymorphic < ActiveRecord::Migration[8.1]
  def up
    add_column :agent_steps, :run_type, :string
    add_column :agent_steps, :run_id, :bigint
    execute "UPDATE agent_steps SET run_type = 'Report', run_id = report_id"
    change_column_null :agent_steps, :run_type, false
    change_column_null :agent_steps, :run_id, false
    add_index :agent_steps, %i[run_type run_id position]
    remove_reference :agent_steps, :report, foreign_key: true, index: true
  end

  # A fit search's steps have no report to go back to, so they go.
  def down
    add_reference :agent_steps, :report, foreign_key: true, index: true
    execute "DELETE FROM agent_steps WHERE run_type <> 'Report'"
    execute "UPDATE agent_steps SET report_id = run_id"
    change_column_null :agent_steps, :report_id, false
    remove_index :agent_steps, %i[run_type run_id position]
    remove_column :agent_steps, :run_id
    remove_column :agent_steps, :run_type
  end
end
