# GET /admin: today's and this month's totals, the budgets, the kill switch, the settings and the latest failures.
module Admin
  class DashboardController < BaseController
    def index
      @stats = Stats.new
      @settings = SettingsForm.current
    end
  end
end
