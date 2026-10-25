# The kill switch for new runs (AppSettings.pause_runs!): POST /admin/pause pauses with a reason, which users see in
# the upgrade prompt; DELETE /admin/pause resumes and emails the notify list.
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

    # Resuming tells the notify list, as the paused notice promised (R81).
    def destroy
      was_paused = AppSettings.runs_paused?
      AppSettings.resume_runs!
      RunsResumedMailJob.perform_later if was_paused
      log_change("resumed new runs")
      redirect_to admin_root_path, notice: "New runs are back on."
    end
  end
end
