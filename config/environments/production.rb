require "active_support/core_ext/integer/time"
require_relative "../../lib/required_env"

# Stop at boot, naming whatever is missing (lib/required_env.rb). The image build precompiles assets in production
# with only SECRET_KEY_BASE_DUMMY set, so that boot is let through.
RequiredEnv.check! unless ENV["SECRET_KEY_BASE_DUMMY"]

# The site's public address (APP_URL, required and checked above), for links in email.
app_url = RequiredEnv.app_uri(ENV["APP_URL"]) || URI("https://midrolo.com")

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Uploaded kit photos go to Cloudflare R2 (config/storage.yml, from the R2_* variables). Image variants need libvips
  # in the container. Active Storage builds its service at boot, so the image build's asset precompile, which has no
  # R2 settings, uses the disk instead.
  config.active_storage.service = ENV["SECRET_KEY_BASE_DUMMY"] ? :local : :r2

  # TLS ends at Traefik (Coolify's proxy on the server), which sends plain http on the Docker network: assume every
  # request came over https. Traefik redirects http to https itself, so force_ssl's redirect never fires (every
  # request already counts as https), and what force_ssl adds is secure cookies and Strict-Transport-Security.
  config.assume_ssl = true
  config.force_ssl = true

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Mail goes out through Resend (the resend gem's delivery method; RESEND_API_KEY, see config/initializers/resend.rb).
  # Errors raise, so a missing key or a rejected send fails the mail job visibly instead of vanishing.
  config.action_mailer.delivery_method = :resend
  config.action_mailer.raise_delivery_errors = true
  # Every message takes a slot from the daily and monthly mail budget first (R143: Resend's free tier).
  config.action_mailer.interceptors = %w[MailBudget]

  # Links in mail point at APP_URL.
  config.action_mailer.default_url_options = { host: app_url.host, protocol: app_url.scheme }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Answer only for the site's own names (DNS rebinding and Host header attacks): midrolo.com, and www, which Traefik
  # redirects to the apex. The health check answers any host: Docker asks for http://localhost/up.
  config.hosts = [ "midrolo.com", "www.midrolo.com", app_url.host ].uniq
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
