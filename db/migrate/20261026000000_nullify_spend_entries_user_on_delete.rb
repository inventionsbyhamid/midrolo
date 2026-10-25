# A deleted account keeps its spend rows, with no owner and no report, so the budget totals (Llm::Budget, the admin
# sums) still add up (R129). The plain user key made User#destroy! fail for anyone with spend. The report key already
# nullifies where the migrations ran in order; re-adding it puts a database that drifted (a development one did) in
# the same state, so down leaves it as it is.
class NullifySpendEntriesUserOnDelete < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :spend_entries, :users
    add_foreign_key :spend_entries, :users, on_delete: :nullify

    remove_foreign_key :spend_entries, :reports
    add_foreign_key :spend_entries, :reports, on_delete: :nullify
  end

  def down
    remove_foreign_key :spend_entries, :users
    add_foreign_key :spend_entries, :users
  end
end
