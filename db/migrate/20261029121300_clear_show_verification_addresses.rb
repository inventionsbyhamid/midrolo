# show_verifications.sent_to is encrypted now (deterministic, so the per-address caps can still query it), and the rows
# written before hold it in plain text. They are spent or short-lived codes and tokens (a show's verified state lives on
# shows.verified_at), so they go instead of being re-encrypted. Nothing comes back on the way down.
class ClearShowVerificationAddresses < ActiveRecord::Migration[8.1]
  def up
    execute "DELETE FROM show_verifications"
  end

  def down; end
end
