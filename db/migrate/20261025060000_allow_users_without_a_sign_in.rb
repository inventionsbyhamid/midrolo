# The samples owner (R78) is a user no one can sign in as: it has no provider or uid, so no OmniAuth callback can ever
# match it. Every other user still has both, and nobody has only one of them.
class AllowUsersWithoutASignIn < ActiveRecord::Migration[8.1]
  def change
    change_column_null :users, :provider, true
    change_column_null :users, :uid, true
    add_check_constraint :users, "(provider IS NULL) = (uid IS NULL)", name: "users_provider_and_uid_together"
  end
end
