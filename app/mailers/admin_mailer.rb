# Mail for whoever runs Midrolo. error is sent by the error reporter (config/initializers/error_reporting.rb), which
# has already scrubbed every field: ids and code locations only, never a secret or a user's data.
class AdminMailer < ApplicationMailer
  layout false

  def error(error_class:, message:, severity:, handled:, source:, context:, backtrace:, occurred_at:)
    recipients = self.class.recipients
    return if recipients.empty?

    @error_class = error_class
    @message = message
    @severity = severity
    @handled = handled
    @source = source
    @context = context
    @backtrace = backtrace
    @occurred_at = occurred_at
    mail to: recipients, subject: "[#{APP_NAME}] #{error_class}"
  end

  # A platform session of Midrolo's stats account stopped working (Stats::ServiceSessions.expired!), so syncs for that
  # platform wait until an admin pastes a new one. Names the platform only; never a cookie.
  def service_session_expired(platform:)
    recipients = self.class.recipients
    return if recipients.empty?

    @platform_name = Stats.platform_name(platform)
    @service_name = Stats.service_name(platform)
    @url = admin_service_sessions_url
    mail to: recipients, subject: "[#{APP_NAME}] The #{@service_name} session expired: stats syncs are paused"
  end

  # ADMIN_EMAIL (comma separated) when set, else every admin account's address.
  def self.recipients
    configured = ENV["ADMIN_EMAIL"].to_s.split(",").map(&:strip).compact_blank
    configured.presence || User.where(admin: true).where.not(email: [ nil, "" ]).order(:id).pluck(:email)
  end
end
