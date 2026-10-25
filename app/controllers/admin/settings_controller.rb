# PATCH /admin/settings: the promo, judge and daily budgets and the promo's last day (Admin::SettingsForm). A refused
# form re-renders the dashboard with its errors and what was typed.
module Admin
  class SettingsController < BaseController
    def update
      @settings = SettingsForm.new(params.expect(settings: SettingsForm.attribute_names.map(&:to_sym)))
      if @settings.save
        log_change("changed #{@settings.changed_settings.join(', ')}") if @settings.changed_settings.any?
        redirect_to admin_root_path, notice: "Settings saved."
      else
        @stats = Stats.new
        render "admin/dashboard/index", status: :unprocessable_content
      end
    end
  end
end
