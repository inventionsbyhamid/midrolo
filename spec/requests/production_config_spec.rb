require "rails_helper"
require "open3"

# Production's configuration, from a real production boot: `bin/rails runner` in a child process, with dummy values
# for what production requires (lib/required_env.rb) and a database host that can't resolve. Nothing connects
# anywhere: the facts come from the configuration, and from requests through the whole middleware stack that never
# reach the database (a public file, and /up, the health check).
RSpec.describe "Production configuration" do
  def dummy_env = {
    "RAILS_ENV" => "production", "SECRET_KEY_BASE" => "0" * 64, "MIDROLO_DATABASE_PASSWORD" => "dummy",
    "DB_HOST" => "db.invalid", "APP_URL" => "https://midrolo.com", "RESEND_API_KEY" => "re_dummy",
    "R2_ACCOUNT_ID" => "acct", "R2_ACCESS_KEY_ID" => "key", "R2_SECRET_ACCESS_KEY" => "secret", "R2_BUCKET" => "kits",
    "QLOO_API_KEY" => "dummy", "PODCAST_INDEX_KEY" => "dummy", "PODCAST_INDEX_SECRET" => "dummy", "VIPS_WARNING" => "0"
  }

  def facts_script = <<~'RUBY'
    app = Rails.application
    get = ->(url, env = {}) { Rack::MockRequest.new(app).get(url, { "HTTP_HOST" => URI(url).host }.merge(env)) }
    status = ->(url, env = {}) { get.(url, env).status }
    facts = {
      hosts: app.config.hosts.map(&:to_s),
      force_ssl: app.config.force_ssl, assume_ssl: app.config.assume_ssl,
      storage: app.config.active_storage.service.to_s,
      mail: app.config.action_mailer.delivery_method.to_s,
      mail_url: app.config.action_mailer.default_url_options,
      database_host: ActiveRecord::Base.configurations.configs_for(env_name: "production").map { |c| c.configuration_hash[:host] }.uniq,
      report_only: app.config.content_security_policy_report_only,
      csp: get.("https://midrolo.com/up")["content-security-policy"].to_s,
      spoof_status: ActionDispatch::ExceptionWrapper.status_code_for_exception("ActionDispatch::RemoteIp::IpSpoofAttackError"),
      cloudflare_proxies: ActionDispatch::RemoteIp.ancestors.include?(CloudflareRails::RemoteIpProxies),
      statuses: {
        apex: status.("https://midrolo.com/icon.svg"), www: status.("https://www.midrolo.com/icon.svg"),
        other_host: status.("https://evil.example/icon.svg"),
        health_any_host: status.("http://localhost/up"), health_container_ip: status.("http://172.18.0.9/up"),
        plain_http: status.("http://midrolo.com/icon.svg"),
        spoofed_client_ip: status.("https://midrolo.com/up", "REMOTE_ADDR" => "172.18.0.5",
                                   "HTTP_X_FORWARDED_FOR" => "198.51.100.1", "HTTP_CLIENT_IP" => "203.0.113.7")
      }
    }
    puts "FACTS #{facts.to_json}"
  RUBY

  # The child gets only the variables given here, of everything RequiredEnv checks (CI sets DATABASE_URL, for one).
  def boot(script, env = dummy_env)
    cleared = RequiredEnv::VARIABLES.flat_map(&:first).index_with { nil }
    Open3.capture3(cleared.merge(env), "bin/rails", "runner", script, chdir: Rails.root.to_s)
  end

  describe "with every required variable set" do
    before(:context) do
      out, err, status = boot(facts_script)
      raise "production didn't boot: #{err.lines.first(5).join}" unless status.success?

      @facts = JSON.parse(out.lines.grep(/\AFACTS /).last.delete_prefix("FACTS "))
    end

    it "answers only for midrolo.com and www.midrolo.com, except the health check, which answers any host" do
      expect(@facts["hosts"]).to contain_exactly("midrolo.com", "www.midrolo.com")
      expect(@facts["statuses"]).to include("apex" => 200, "www" => 200, "other_host" => 403,
                                            "health_any_host" => 200, "health_container_ip" => 200)
    end

    it "takes TLS as ended at the proxy: assume_ssl, force_ssl, and plain http is never redirected again" do
      expect(@facts).to include("assume_ssl" => true, "force_ssl" => true)
      expect(@facts["statuses"]["plain_http"]).to eq(200)
    end

    it "stores uploads on R2, sends mail through Resend with links to APP_URL, and finds the database on DB_HOST" do
      expect(@facts).to include("storage" => "r2", "mail" => "resend", "database_host" => [ "db.invalid" ])
      expect(@facts["mail_url"]).to eq("host" => "midrolo.com", "protocol" => "https")
    end

    it "enforces the Content Security Policy" do
      expect(@facts["report_only"]).to be(false)
      expect(@facts["csp"]).to include("script-src 'self' https://cdn.jsdelivr.net 'nonce-")
    end

    it "trusts Cloudflare's ranges as proxies, and answers a Client-IP that disagrees with X-Forwarded-For with a 400" do
      expect(@facts["cloudflare_proxies"]).to be(true)
      expect(@facts["spoof_status"]).to eq(400)
      expect(@facts["statuses"]["spoofed_client_ip"]).to eq(400) # at production's log level, which logs remote_ip
    end
  end

  it "stops at boot, naming each missing variable" do
    _out, err, status = boot("puts :booted", dummy_env.except("R2_BUCKET", "APP_URL"))

    expect(status).not_to be_success
    expect(err).to include("Production is missing environment variables:", "  APP_URL: ", "  R2_BUCKET: ")
    expect(err).not_to include("RESEND_API_KEY")
  end

  # The Docker build precompiles assets in production with only SECRET_KEY_BASE_DUMMY set.
  it "boots for the image build's asset precompile with no variables but SECRET_KEY_BASE_DUMMY" do
    out, err, status = boot("puts :booted", { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1", "VIPS_WARNING" => "0" })

    expect(status).to be_success, err.lines.first(5).join
    expect(out).to include("booted")
  end
end
