require "rails_helper"

# Links in development mail (and the email logo's URL, which is built from root_url) point at APP_URL, else
# localhost on PORT, 3100 by default: never 3000, another project's port on this machine (Task 20).
RSpec.describe DevUrlOptions do
  it "reads host, port and protocol from APP_URL" do
    expect(described_class.call("APP_URL" => "https://midrolo.test:8443/", "PORT" => "4000"))
      .to eq(host: "midrolo.test", port: 8443, protocol: "https")
    expect(described_class.call("APP_URL" => "http://dev.midrolo.test")).to eq(host: "dev.midrolo.test", protocol: "http")
  end

  it "falls back to localhost on PORT, and 3100 without one" do
    expect(described_class.call("PORT" => "3200")).to eq(host: "localhost", port: 3200)
    expect(described_class.call({})).to eq(host: "localhost", port: 3100)
    expect(described_class.call("APP_URL" => " ", "PORT" => "")).to eq(host: "localhost", port: 3100)
  end

  # foreman gives each Procfile.dev process a PORT of its own: the web server the base port, the others 100 more each.
  # The job worker sends most mail, so on its own PORT every link and the logo pointed where nothing listens (Task 23).
  it "prefers WEB_PORT, the web server's port that bin/dev sets, over a process's own PORT" do
    expect(described_class.call("WEB_PORT" => "3200", "PORT" => "3400")).to eq(host: "localhost", port: 3200)
    expect(described_class.call("WEB_PORT" => " ", "PORT" => "3400")).to eq(host: "localhost", port: 3400)
    expect(described_class.call("APP_URL" => "https://midrolo.test", "WEB_PORT" => "3200"))
      .to eq(host: "midrolo.test", protocol: "https")
  end

  it "gets WEB_PORT from bin/dev: the base PORT, which foreman gives the web server, first in Procfile.dev" do
    bin_dev = Rails.root.join("bin/dev").read

    expect(bin_dev).to match(/^export WEB_PORT="\$PORT"$/)
    expect(bin_dev.index('export PORT="${PORT:-3100}"')).to be < bin_dev.index('export WEB_PORT="$PORT"')
    expect(Rails.root.join("Procfile.dev").read.lines.first).to start_with("web: ")
  end

  it "is what development mail uses, with no port 3000 left in the config" do
    config = Rails.root.join("config/environments/development.rb").read

    expect(config).to include("config.action_mailer.default_url_options = DevUrlOptions.call")
    expect(config).not_to match(/port: 3000/)
  end

  # GitHub Codespaces serves the app at https://<codespace>-3100.app.github.dev; the dev container sets
  # RAILS_DEVELOPMENT_HOSTS so Rails allows that host, and these let Action Cable take connections from its pages.
  describe ".proxy_origins" do
    it "matches pages on each RAILS_DEVELOPMENT_HOSTS host, a leading dot taking every subdomain" do
      origins = described_class.proxy_origins("RAILS_DEVELOPMENT_HOSTS" => ".app.github.dev, dev.midrolo.test")

      expect(origins.size).to eq(2)
      match = ->(origin) { origins.any? { |pattern| pattern.match?(origin) } }
      expect(match.("https://fuzzy-robot-5x7-3100.app.github.dev")).to be(true)
      expect(match.("https://app.github.dev")).to be(true)
      expect(match.("http://dev.midrolo.test:3100")).to be(true)
      expect(match.("https://evil.dev.midrolo.test")).to be(false)
      expect(match.("https://app.github.dev.evil.example")).to be(false)
      expect(match.("https://xapp.github.dev")).to be(false)
    end

    it "is empty without RAILS_DEVELOPMENT_HOSTS, so development keeps Rails' own checks" do
      expect(described_class.proxy_origins({})).to eq([])
      expect(described_class.proxy_origins("RAILS_DEVELOPMENT_HOSTS" => " , ")).to eq([])
    end
  end
end
