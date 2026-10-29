# The environment production can't run without (Task 21). config/environments/production.rb checks it at boot, so a
# missing variable stops the web, jobs and console processes straight away, by name, instead of failing later on the
# first upload, email or page. Loaded by production.rb, before autoloading.
#
# Everything else is optional: ADMIN_USERNAME/ADMIN_PASSWORD (unset, /admin is a 404), ADMIN_EMAIL (unset, every
# admin account gets the error mail), OPENROUTER_API_KEY (the LLM's: runs fail until it's set), GOOGLE_CLIENT_*
# (sign in fails until they're set) and DODO_* (billing stays a waitlist). QLOO_API_KEY and PODCAST_INDEX_* are
# required even though they're optional elsewhere: outside production a blank key means demo data, but production has
# no demo data, and every page asks whether it's showing some (DemoMode), so without them no page renders.
module RequiredEnv
  class Missing < StandardError; end

  # [names, purpose]: any one of the names will do.
  VARIABLES = [
    [ %w[SECRET_KEY_BASE RAILS_MASTER_KEY], "signs sessions and cookies (or the master key, to read it from the credentials)" ],
    [ %w[MIDROLO_DATABASE_PASSWORD DATABASE_URL], "the database: the compose stack's password, or a full URL" ],
    [ %w[APP_URL], "the site's public address, for links in email (https://midrolo.com)" ],
    [ %w[RESEND_API_KEY], "sends email through Resend" ],
    [ %w[R2_ACCOUNT_ID], "Cloudflare R2, where uploads are stored: the account id" ],
    [ %w[R2_ACCESS_KEY_ID], "Cloudflare R2: the API token's access key id" ],
    [ %w[R2_SECRET_ACCESS_KEY], "Cloudflare R2: the API token's secret" ],
    [ %w[R2_BUCKET], "Cloudflare R2: the bucket for uploads" ],
    [ %w[QLOO_API_KEY], "taste data from Qloo (production has no demo data)" ],
    [ %w[PODCAST_INDEX_KEY], "the podcast directory, Podcast Index (production has no demo data)" ],
    [ %w[PODCAST_INDEX_SECRET], "the podcast directory, Podcast Index" ]
  ].freeze

  module_function

  # The entries none of whose names has a value.
  def missing(env = ENV) = VARIABLES.reject { |names, _| names.any? { |name| env[name].to_s.strip != "" } }

  # APP_URL as a URI when it's an absolute http(s) address with a host, else nil.
  def app_uri(value)
    uri = URI.parse(value.to_s.strip)
    uri if uri.is_a?(URI::HTTP) && uri.host.to_s != ""
  rescue URI::InvalidURIError
    nil
  end

  # Names what's wrong, never a value: these lines end up in logs.
  def check!(env = ENV)
    lines = missing(env).map { |names, purpose| "  #{names.join(' or ')}: #{purpose}\n" }
    if env["APP_URL"].to_s.strip != "" && !app_uri(env["APP_URL"])
      lines << "  APP_URL: isn't an absolute http(s) address, such as https://midrolo.com\n"
    end
    return if lines.empty?

    raise Missing, "Production can't start until these environment variables are set right:\n#{lines.join}" \
                   "Set them in .env (see .env.example), then start again."
  end
end
