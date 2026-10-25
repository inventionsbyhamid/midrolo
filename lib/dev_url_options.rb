# Where links in development mail point (config.action_mailer.default_url_options), and so the email logo's URL, which
# is built from root_url: APP_URL when it is set, else localhost on the web server's port, 3100 by default. Never
# 3000, another project's port on this machine (Task 20). Loaded by config/environments/development.rb, before
# autoloading.
#
# The web server's port is WEB_PORT, which bin/dev sets, else PORT. Under bin/dev, foreman gives each process in
# Procfile.dev a PORT of its own (the web server the base port, the others 100 more each), so the job worker, which
# sends most mail, can't go by its own PORT (Task 23).
module DevUrlOptions
  DEFAULT_PORT = 3100

  module_function

  def call(env = ENV)
    url = env["APP_URL"].to_s.strip
    if url.empty?
      port = env["WEB_PORT"].to_s.strip.presence || env["PORT"].to_s.strip.presence || DEFAULT_PORT
      return { host: "localhost", port: Integer(port) }
    end

    uri = URI.parse(url)
    { host: uri.host, port: (uri.port unless uri.port == uri.default_port), protocol: uri.scheme }.compact
  end
end
