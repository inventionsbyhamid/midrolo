# /admin/service_sessions: Midrolo's own sessions on Spotify for Creators and Apple Podcasts Connect (build spec
# section 11), which bin/platform-stats signs in with. An admin pastes the cookies into a form; they are encrypted and
# never shown, logged or put back in a form again (the params are filtered as "credentials"). Test fetch reads one
# connection's numbers right away, without saving them, to prove a session works; it is a helper run like any other,
# so it waits for Stats::Throttle (it doesn't run when the platform's limits say not yet). The page also shows each
# platform's throttle (runs in the last hour and day, the next allowed run, cooldown, failures) and edits its limits
# (Stats::Limits).
#
# Inside module Admin, Stats is Admin::Stats, so the stats services are written ::Stats.
module Admin
  class ServiceSessionsController < BaseController
    before_action :set_platform, only: %i[update test]

    def index
      @sessions = ServiceSession.where(platform: ::Stats::PLATFORMS.keys).index_by(&:platform)
      @connections = StatConnection.where(provider: ::Stats::PLATFORMS.keys).includes(:podcast).order(updated_at: :desc)
                                   .limit(100).group_by(&:provider)
      @limits ||= ::Stats::Limits.current
      limits = ::Stats::Limits.current
      @throttles = @sessions.transform_values { |session| ::Stats::Throttle.status(session, limits: limits) }
    end

    # The throttle's limits, for every platform. A refused form shows the page again with what was typed.
    def limits
      @limits = ::Stats::Limits.new(params.expect(limits: ::Stats::Limits::DEFAULTS.keys))
      if @limits.save
        log_change("changed the stats limits: #{@limits.changed_settings.join(', ')}") if @limits.changed_settings.any?
        redirect_to admin_service_sessions_path(anchor: "limits"), notice: "Limits saved.", status: :see_other
      else
        index
        render :index, status: :unprocessable_content
      end
    end

    def update
      values = params.fetch(:credentials, {}).permit(*::Stats::PLATFORMS.dig(@platform, :session_keys)).to_h
      ::Stats::ServiceSessions.save!(@platform, values, expires_hint: expires_hint)
      log_change("saved the #{@platform} service session")
      redirect_to admin_service_sessions_path, status: :see_other,
                                               notice: "#{::Stats.service_name(@platform)} session saved. It won't be shown again."
    rescue ::Stats::ServiceSessions::Invalid => e
      redirect_to admin_service_sessions_path, alert: e.message, status: :see_other
    end

    # Runs the helper now against a connection (or a show id typed in) and shows what came back. Saves nothing but
    # what it learns about the session: working, or expired.
    def test
      connection = test_connection
      return redirect_to(admin_service_sessions_path, alert: "Choose a connection or enter a show id.", status: :see_other) unless connection

      slot = ::Stats::Throttle.reserve(@platform, book: false)
      unless slot.allowed?
        return redirect_to(admin_service_sessions_path(anchor: @platform), status: :see_other,
                           alert: "Not yet: #{::Stats.platform_name(@platform)}'s limits allow the next run at " \
                                  "#{slot.at.utc.strftime('%H:%M:%S')} UTC.")
      end

      session = ServiceSession.find_by(platform: @platform)
      @result = ::Stats::Throttle.track(@platform) { ::Stats::PlatformFetch.call(connection, session: session) }
      if @result["ok"]
        ::Stats::ServiceSessions.worked!(session)
      elsif @result["error"] == "expired"
        ::Stats::ServiceSessions.expired!(session, @result["message"])
      end
      @tested = connection
      log_change("ran a #{@platform} test fetch: #{@result['ok'] ? 'ok' : @result['error']}")
      index
      render :index
    end

    private

    def set_platform
      @platform = params[:platform].to_s
      raise ActionController::RoutingError, "Not Found" unless ::Stats.platform?(@platform)
    end

    def expires_hint
      Date.iso8601(params[:expires_hint].to_s).in_time_zone("UTC")
    rescue Date::Error
      nil
    end

    def test_connection
      if params[:connection_id].present?
        StatConnection.find_by(id: params[:connection_id], provider: @platform)
      elsif (show_id = ::Stats.show_id_from(@platform, params[:show_id]))
        StatConnection.new(provider: @platform, external_id: show_id)
      end
    end
  end
end
