# GET /admin: today's and this month's totals, the budgets, the kill switch, the settings and the latest failures.
module Admin
  class DashboardController < BaseController
    # The marketplace lanes' panels, in order: admin/dashboard/_<panel>.html.erb, each filled by its lane (catalog
    # counts and ingest errors L1, sponsor detection and the catalog LLM spend L2, stats connections and service
    # sessions L5, reported conversations L7).
    PANELS = %w[catalog sponsors stats conversations].freeze

    def index
      @stats = Stats.new
      @settings = SettingsForm.current
    end
  end
end
