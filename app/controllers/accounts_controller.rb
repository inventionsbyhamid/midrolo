class AccountsController < ApplicationController
  JUDGE_CODE_TRIES = 5
  JUDGE_CODE_WINDOW = 1.hour

  layout "app"
  before_action :authenticate_user!
  # Guesses at JUDGE_CODE, per user (R83). Rack::Attack limits them too; this one holds however the path is spelled.
  rate_limit to: JUDGE_CODE_TRIES, within: JUDGE_CODE_WINDOW, only: :judge_code, by: -> { current_user.id },
             store: RATE_LIMIT_STORE, with: -> { render_throttled(retry_after: JUDGE_CODE_WINDOW) }

  def show; end

  def judge_code
    if judge_code_valid?(params[:code])
      current_user.update!(judge: true)
      redirect_to account_path, notice: "Judge access unlocked — enjoy full Pro features."
    else
      redirect_to account_path, alert: "That code didn't work."
    end
  end

  def destroy
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
