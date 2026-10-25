require_relative "../../lib/auth_config"

# OmniAuth-only Devise: Google sign-in mints the session, there are no passwords.
Devise.setup do |config|
  require "devise/orm/active_record"

  config.mailer_sender = "no-reply@midrolo.com"
  config.sign_out_via = :delete
  config.navigational_formats = [ "*/*", :html ]
  config.responder.redirect_status = :see_other
  config.responder.error_status = :unprocessable_entity
  config.skip_session_storage = [ :http_auth ]
  config.remember_for = 2.weeks

  config.omniauth :google_oauth2,
                  ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"],
                  scope: "email,profile",
                  prompt: "select_account",
                  access_type: "online"

  if AuthConfig.developer_strategy?
    config.omniauth :developer, **AuthConfig::DEVELOPER_OPTIONS
  end
end

OmniAuth.config.allowed_request_methods = [ :post ]
