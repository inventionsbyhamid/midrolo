class AccountsController < ApplicationController
  # R132: deleting the account would leave the provider charging a plan nobody can use.
  CANCEL_FIRST = "Cancel your plan in Manage billing first, then delete your account.".freeze

  layout "app"
  before_action :authenticate_user!
  before_action :refuse_while_masquerading, only: :destroy

  def show; end

  def destroy
    return redirect_to(account_path, alert: CANCEL_FIRST) if current_user.renewing_subscription?

    current_user.destroy!
    sign_out
    redirect_to "/", notice: "Your account and data were deleted."
  end
end
