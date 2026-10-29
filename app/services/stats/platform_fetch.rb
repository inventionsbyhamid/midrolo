require "open3"

module Stats
  # Reads one stats connection's numbers from its platform (build spec section 11). It runs bin/platform-stats (the
  # Python helper built on openpodcast's connectors) with one JSON request on stdin: the platform, Midrolo's own
  # service session for it (ServiceSession), the show id and a 30-day window ending yesterday (UTC; the platforms only
  # count a day once it has ended), or a longer window (days:) for an audience a month can't show. The answer is one JSON object on stdout, checked and returned with string keys:
  #
  #   { "ok" => true, "platform" =>, "show" => { "id", "name", "rss_url" }, "period" => { "start", "end", "days" },
  #     "metrics" => { "streams" => 50, ... }, "breakdowns" => { "age" => { "18-22" => 0.25, ... }, ... },
  #     "unavailable" => [ keys a call the platform didn't answer this time would have given ] }
  #   { "ok" => false, "error" => "expired" | "forbidden" | "not_found" | "failed" | "unavailable", "message" => ... }
  #
  # "unavailable" is this class's own: there is no working session for the platform, so nothing was asked.
  #
  # The session goes only to the helper's stdin. It is never in the command line, the environment, a log line, an
  # exception or the result, and the helper's stderr is scrubbed of it before a line of it is logged. The helper gets a
  # bare environment (PATH and locale only), so the app's own secrets never reach it either. It must finish within
  # TIMEOUT seconds or its whole process group is killed.
  class PlatformFetch
    TIMEOUT = 60
    # The window: 30 days ending yesterday, inclusive. AUDIENCE_DAYS is the longer one for a breakdown a month of
    # listens can't give (the helper takes at most 366).
    WINDOW_DAYS = 30
    AUDIENCE_DAYS = 365
    MAX_OUTPUT = 256 * 1024
    ERRORS = %w[expired forbidden not_found failed unavailable].freeze
    SAFE_KEY = /\A[a-z0-9_+\-]{1,40}\z/i
    # Environment variables the helper may see: where programs are, the locale, and an outbound proxy if the host has
    # one, and the Python a developer points it at. Nothing else (no database URL, no Rails or encryption keys).
    PASSED_ENV = %w[PATH LANG LC_ALL HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy
                    PLATFORM_STATS_PYTHON].freeze

    class_attribute :command, default: nil

    def self.call(connection, session: nil, days: WINDOW_DAYS, timeout: TIMEOUT)
      new(connection, session:, days:, timeout:).call
    end

    # bin/platform-stats, unless a spec set another command.
    def self.helper_command = command || [ Rails.root.join("bin/platform-stats").to_s ]

    def self.failure(error, message) = { "ok" => false, "error" => error, "message" => message }

    def initialize(connection, session:, days:, timeout:)
      @connection = connection
      @session = session || ServiceSession.find_by(platform: connection.provider)
      @days = days.to_i.clamp(1, AUDIENCE_DAYS)
      @timeout = timeout
    end

    def call
      values = session_values
      return values if values.is_a?(Hash) && values["ok"] == false

      @secrets = values.values.map(&:to_s).select { |value| value.length >= 4 }
      stdout, stderr, status = run(JSON.generate(request(values)))
      log_stderr(stderr, status)
      parse(stdout, status)
    rescue Errno::ENOENT, Errno::EACCES
      log("helper missing")
      self.class.failure("failed", "The stats helper isn't installed on this server.")
    rescue StandardError => e
      # Only the class: a message could carry part of what the helper was given.
      log("error #{e.class.name}")
      self.class.failure("failed", "Something went wrong reading the numbers (#{e.class.name}).")
    end

    private

    attr_reader :connection, :session, :days, :timeout

    def request(values)
      last_day = Time.now.utc.to_date - 1
      { platform: connection.provider, session: values, show_id: connection.external_id.to_s,
        start: (last_day - (days - 1)).iso8601, end: last_day.iso8601 }
    end

    # The session's cookies as a Hash of strings, or a failure when there is none that works. The stored JSON is never
    # parsed where an error could quote it: a parse error's message would carry the secret.
    def session_values
      name = Stats.platform_name(connection.provider)
      return self.class.failure("unavailable", "Midrolo's #{name} session isn't set up yet.") if session.nil? || session.credentials.blank?
      return self.class.failure("unavailable", "Midrolo's #{name} session has expired.") unless session.ok?

      values = begin
        JSON.parse(session.credentials)
      rescue JSON::ParserError
        nil
      end
      unless values.is_a?(Hash) && values.any? && values.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
        return self.class.failure("unavailable", "Midrolo's #{name} session isn't readable. Enter it again.")
      end

      values
    end

    # Runs the helper in its own process group with a bare environment, the request on stdin. Returns [stdout, stderr,
    # status], or [nil, nil, :timeout] when it ran past the timeout (and was killed with everything it started).
    def run(input)
      env = ENV.to_h.slice(*PASSED_ENV).merge("PYTHONDONTWRITEBYTECODE" => "1", "PYTHONIOENCODING" => "utf-8")
      Open3.popen3(env, *self.class.helper_command, unsetenv_others: true, pgroup: true) do |stdin, stdout, stderr, wait|
        out = Thread.new { stdout.read(MAX_OUTPUT + 1) }
        err = Thread.new { stderr.read(MAX_OUTPUT) }
        # A killed helper's pipes close under the readers; that's expected, not worth a warning.
        [ out, err ].each { |reader| reader.report_on_exception = false }
        begin
          stdin.write(input)
        rescue Errno::EPIPE
          nil # it quit before reading; its exit status says why
        ensure
          stdin.close
        end

        if wait.join(timeout).nil? || out.join(5).nil?
          kill(wait.pid)
          return [ nil, nil, :timeout ]
        end

        [ out.value, err.join(5) && err.value, wait.value ]
      end
    end

    def kill(pid)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def parse(stdout, status)
      if status == :timeout
        log("timeout")
        return self.class.failure("failed", "The platform took longer than #{timeout} seconds to answer.")
      end
      return self.class.failure("failed", "The stats helper's answer was too long.") if stdout.to_s.bytesize > MAX_OUTPUT

      body = begin
        JSON.parse(stdout.to_s)
      rescue JSON::ParserError
        nil
      end
      unless body.is_a?(Hash)
        log("unreadable answer, exit #{status&.exitstatus.inspect}")
        return self.class.failure("failed", "The stats helper gave an answer we couldn't read.")
      end

      body["ok"] == true && status&.success? ? success(body) : error(body)
    end

    def success(body)
      metrics = hash(body["metrics"]).each_with_object({}) do |(key, value), kept|
        kept[key] = value if key.match?(SAFE_KEY) && value.is_a?(Integer) && value >= 0
      end
      breakdowns = hash(body["breakdowns"]).select { |key, value| key.match?(SAFE_KEY) && (value.is_a?(Hash) || value.is_a?(Array)) }
      return self.class.failure("failed", "The platform answered without any numbers.") if metrics.empty?

      show = hash(body["show"]).slice("id", "name", "rss_url").transform_values { |value| scrub(value.to_s).first(300) }
      period = hash(body["period"]).slice("start", "end", "days")
      unavailable = Array(body["unavailable"]).map(&:to_s).grep(SAFE_KEY).first(50)
      log("ok, #{metrics.size} metrics#{", unavailable: #{unavailable.join(' ')}" if unavailable.any?}")
      { "ok" => true, "platform" => connection.provider, "show" => show, "period" => period, "metrics" => metrics,
        "breakdowns" => breakdowns, "unavailable" => unavailable }
    end

    def error(body)
      code = ERRORS.include?(body["error"]) ? body["error"] : "failed"
      message = scrub(body["message"].to_s).squish.first(300).presence || "The platform didn't give the numbers."
      log("#{code}: #{message}")
      self.class.failure(code, message)
    end

    def hash(value) = value.is_a?(Hash) ? value : {}

    # The helper already keeps secrets out of what it writes; this is the second lock.
    def scrub(text)
      (@secrets || []).reduce(text.to_s) { |scrubbed, secret| scrubbed.gsub(secret, "[FILTERED]") }
    end

    def log_stderr(stderr, status)
      return if stderr.blank? || status == :timeout || status&.success?

      log("stderr: #{scrub(stderr).squish.last(500)}")
    end

    def log(message)
      Rails.logger.info("[Stats::PlatformFetch] #{connection.provider} connection #{connection.id || 'test'}: #{message}")
    end
  end
end
