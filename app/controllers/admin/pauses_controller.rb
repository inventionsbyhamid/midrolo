# The kill switch for new runs (AppSettings.pause_runs!): POST /admin/pause pauses with a reason, which users see in
# the upgrade prompt; DELETE /admin/pause resumes.
module Admin
  class PausesController < BaseController
    REASON_MAX = 200

    def create
      reason = params[:reason].to_s.squish
      return redirect_to(admin_root_path, alert: "Give a reason for pausing. Users see it.") if reason.blank?
      if reason.length > REASON_MAX
        return redirect_to(admin_root_path, alert: "Keep the reason to #{REASON_MAX} characters or fewer.")
      end

      AppSettings.pause_runs!(reason)
      log_change("paused new runs: #{reason}")
      redirect_to admin_root_path, notice: "New runs are paused."
    end

    def destroy
      AppSettings.resume_runs!
      log_change("resumed new runs")
      redirect_to admin_root_path, notice: "New runs are back on."
    end
  end
end
