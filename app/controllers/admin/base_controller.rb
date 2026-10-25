# The admin area's one guard (R68), for the dashboard and for Mission Control Jobs at /admin/jobs (its base controller,
# config/application.rb). It takes both a signed-in admin and HTTP basic auth against ADMIN_USERNAME and
# ADMIN_PASSWORD. Anyone who isn't a signed-in admin gets the ordinary 404, before any basic-auth challenge, so the
# area's existence doesn't leak; with either variable unset, it is a 404 for everyone.
module Admin
  class BaseController < ApplicationController
    layout "app"
    before_action :require_admin
    before_action :require_basic_auth

    private

    def require_admin
      raise ActionController::RoutingError, "Not Found" unless credentials_set? && current_user&.admin?
    end

    def require_basic_auth
      authenticate_or_request_with_http_basic("Admin") do |username, password|
        # & rather than &&: both comparisons always run.
        ActiveSupport::SecurityUtils.secure_compare(username, ENV.fetch("ADMIN_USERNAME")) &
          ActiveSupport::SecurityUtils.secure_compare(password, ENV.fetch("ADMIN_PASSWORD"))
      end
    end

    def credentials_set? = ENV["ADMIN_USERNAME"].present? && ENV["ADMIN_PASSWORD"].present?

    # Who changed something, for the log: "[Admin] ops@example.com (user 7)".
    def log_change(message)
      Rails.logger.info("[Admin] #{current_user.email} (user #{current_user.id}) #{message}")
    end
  end
end
