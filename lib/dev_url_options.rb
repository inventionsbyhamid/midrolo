# Where links in development mail point (config.action_mailer.default_url_options), and so the email logo's URL, which
# is built from root_url: APP_URL when it is set, else localhost on PORT, 3100 by default. Never 3000, another
# project's port on this machine (Task 20). Loaded by config/environments/development.rb, before autoloading.
module DevUrlOptions
  DEFAULT_PORT = 3100

  module_function

  def call(env = ENV)
    url = env["APP_URL"].to_s.strip
    return { host: "localhost", port: Integer(env["PORT"].to_s.strip.presence || DEFAULT_PORT) } if url.empty?

    uri = URI.parse(url)
    { host: uri.host, port: (uri.port unless uri.port == uri.default_port), protocol: uri.scheme }.compact
  end
end
