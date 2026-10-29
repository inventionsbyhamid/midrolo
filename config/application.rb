require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Midrolo
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # Mission Control Jobs (/admin/jobs) sits behind the admin area's own guard (R68), so its built-in basic auth is off:
    # one auth path for all of /admin.
    config.mission_control.jobs.base_controller_class = "Admin::BaseController"
    config.mission_control.jobs.http_basic_auth_enabled = false

    # A Client-IP header that disagrees with X-Forwarded-For is the client's doing: a 400, never a 500 and an error mail.
    # ClientIp::RejectConflictingHeaders (config/initializers/client_ip.rb) answers it before Rails' request log can
    # raise it outside ShowExceptions; this covers it anywhere else.
    config.action_dispatch.rescue_responses["ActionDispatch::RemoteIp::IpSpoofAttackError"] = :bad_request

    # Active Record encryption: feed owner emails (Podcast), verification addresses (ShowVerification, deterministic so
    # the per-address caps can query them) and stats connector credentials (StatConnection). The keys come from ENV
    # (make a set with bin/rails db:encryption:init); production requires them (RequiredEnv), and development and test
    # fall back to fixed keys of their own.
    config.active_record.encryption.primary_key = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].presence
    config.active_record.encryption.deterministic_key = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].presence
    config.active_record.encryption.key_derivation_salt = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].presence

    # Active Storage's analysis and variant jobs run on the artwork queue (config/queue.yml), with the artwork fetches:
    # catalog artwork brings many at once, and they mustn't hold up reports or mail.
    config.active_storage.queues.analysis = :artwork
    config.active_storage.queues.transform = :artwork
  end
end
