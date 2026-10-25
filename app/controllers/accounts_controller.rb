class AccountsController < ApplicationController
  JUDGE_CODE_TRIES = 5
  JUDGE_CODE_WINDOW = 1.hour
  # R132: deleting the account would leave the provider charging a plan nobody can use.
  CANCEL_FIRST = "Cancel your plan in Manage billing first, then delete your account.".freeze

  layout "app"
  before_action :authenticate_user!
  # Guesses at JUDGE_CODE, per user and per IP (R83).
  throttle to: JUDGE_CODE_TRIES, within: JUDGE_CODE_WINDOW, only: :judge_code, by: -> { current_user.id }, name: "per_user"
  throttle to: JUDGE_CODE_TRIES, within: JUDGE_CODE_WINDOW, only: :judge_code, by: -> { request.remote_ip }, name: "per_ip"

  def show; end

  def judge_code
    if judge_code_valid?(params[:code])
      current_user.update!(judge: true)
      redirect_to account_path, notice: "Judge access unlocked. Enjoy full Pro features."
    else
      redirect_to account_path, alert: "That code didn't work."
    end
  end

  def destroy
    return redirect_to(account_path, alert: CANCEL_FIRST) if current_user.renewing_subscription?

    current_user.destroy!
    sign_out
    redirect_to "/", notice: "Your account and data were deleted."
  end

  private

  # A blank configured code never matches, even against a blank submission.
  def judge_code_valid?(submitted)
    expected = ENV["JUDGE_CODE"].to_s
    expected.present? && ActiveSupport::SecurityUtils.secure_compare(submitted.to_s, expected)
  end
end
