# Errors reported to the Rails error reporter (Rails.error: unhandled ones from requests and jobs, and the app's own
# Rails.error.report calls) email the admin through AdminMailer.error (spec §12), at most once per error class every
# 10 minutes, counted in Rails.cache. Never in test: specs email no one.
#
# The mail carries ids and code locations only (Task 20): the message is scrubbed of email addresses, credentials in
# URLs, secrets from ENV and anything token shaped; the context keeps numbers, ids, a few strings the app writes
# itself, and controllers, jobs and records as class names (with the record's id); the backtrace keeps the app's own
# lines. A subscriber must never raise, so any trouble here is logged and dropped. While it works it is switched off
# for whatever it reports itself: Solid Cache reports its own failures to Rails.error, and a cache that is down would
# otherwise bring every report back here.
module ErrorReporting
  class AdminMailSubscriber
    WINDOW = 10.minutes
    MESSAGE_LIMIT = 300
    BACKTRACE_LINES = 12
    STRING_LIMIT = 80
    # Context strings the app writes itself (Rails.error.report calls), safe to show as they are.
    SAFE_STRING_KEYS = %w[while job share_image].freeze
    SECRET_ENV_NAME = /KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL|CODE/ # CODE: JUDGE_CODE
    SECRET_MIN_LENGTH = 8
    EMAIL = /[^\s@<>"'(),;:]+@[^\s@<>"'(),;:]+\.[a-z]{2,}/i
    URL_CREDENTIALS = %r{(\w+://)[^/\s:@]+:[^/\s@]+@}
    TOKEN = /\b[A-Za-z0-9_\-]{32,}\b/

    def initialize(cache: nil)
      @cache = cache
    end

    def report(error, handled:, severity:, context:, source: nil)
      return if severity == :info

      Rails.error.disable(self) do
        next unless first_in_window?(error.class.name)

        AdminMailer.error(error_class: error.class.name, message: scrub(error.message), severity: severity.to_s,
                          handled: handled, source: source.to_s, context: safe_context(context),
                          backtrace: app_backtrace(error), occurred_at: Time.current.utc.iso8601).deliver_later
      end
    rescue StandardError => e
      Rails.logger.error("[ErrorReporting] couldn't email the admin about #{error.class}: #{e.class}")
    end

    private

    def cache = @cache || Rails.cache

    # The first report of this class in the window; false when the cache can't count, so a broken cache never turns
    # into one mail per error.
    def first_in_window?(error_class)
      cache.increment("error_reporting:admin_mail:#{error_class}", 1, expires_in: WINDOW) == 1
    end

    def scrub(message)
      text = message.to_s.dup
      secrets.each { |secret| text.gsub!(secret, "[secret]") }
      text.gsub(URL_CREDENTIALS, '\1[secret]@').gsub(EMAIL, "[email]").gsub(TOKEN, "[secret]").truncate(MESSAGE_LIMIT)
    end

    def secrets
      ENV.filter_map { |name, value| value if name.match?(SECRET_ENV_NAME) && value.to_s.length >= SECRET_MIN_LENGTH }
         .sort_by { |value| -value.length }
    end

    def safe_context(context)
      context.to_h.each_with_object({}) do |(key, value), safe|
        shown = safe_value(key.to_s, value)
        safe[key.to_s] = shown unless shown.nil?
      end
    end

    def safe_value(key, value)
      case value
      when Integer, Float, true, false then value
      when String then value.truncate(STRING_LIMIT) if SAFE_STRING_KEYS.include?(key) || value.match?(/\A\d+\z/)
      when ActionController::Metal then "#{value.class.name}##{value.action_name}"
      when ActiveJob::Base then value.class.name
      when ActiveRecord::Base then "#{value.class.name} #{value.id}"
      end
    end

    def app_backtrace(error) = Rails.backtrace_cleaner.clean(Array(error.backtrace)).first(BACKTRACE_LINES)
  end
end

Rails.error.subscribe(ErrorReporting::AdminMailSubscriber.new) unless Rails.env.test?
