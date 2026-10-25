class AddSentToIndexToShowVerifications < ActiveRecord::Migration[8.1]
  def change
    # Verification emails are capped per recipient address across every show and account (R65); sent_to is stored
    # normalized (downcased, stripped), so the cap is a plain indexed lookup.
    add_index :show_verifications, %i[sent_to created_at]
  end
end
