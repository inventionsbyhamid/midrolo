# Rate limits (spec §9a, §11; R69, R83). Counters live in RATE_LIMIT_STORE: Rails.cache (Solid Cache) in production, a
# MemoryStore in specs that spec/support/rack_attack.rb clears before every example. In specs Rack::Attack is off, so
# suites that make many requests from 127.0.0.1 never see a 429; examples tagged :rack_attack turn it on. The 429
# itself is ThrottledResponse.
#
# Per-IP limits key on req.ip: the client's address from X-Forwarded-For behind the proxies Rack trusts (never the
# Forwarded header, config/initializers/client_ip.rb). Per-user limits key on the signed-in user that Warden (which runs
# before Rack::Attack) found in the session, and on the IP when signed out. Every rule matches the path the router
# sees (Rack::Attack::Request#route_path), so a format, doubled slashes or a trailing slash can't dodge a limit. The
# controllers' own rate_limit calls still apply on top of these.
RATE_LIMIT_STORE = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache

class Rack::Attack::Request
  # The path as the router matches it: slashes squeezed, no trailing slash and no format, so "/account//judge_code/"
  # and "/account/judge_code.html" are both "/account/judge_code".
  def route_path
    @route_path ||= ActionDispatch::Journey::Router::Utils.normalize_path(path).sub(/\.\w+\z/, "")
  end

  # HEAD runs the GET action.
  def read? = get? || head?

  # The signed-in user, or the IP when signed out.
  def user_or_ip
    user_id = env["warden"]&.user&.id
    user_id ? "user:#{user_id}" : "ip:#{ip}"
  end
end

module RackAttackRules
  # Never counted against the per-IP limit: static files, the health check, Action Cable, uploads, provider webhooks.
  UNCOUNTED_PATHS = %r{\A/(?:assets|up|cable|rails/active_storage|webhooks)(?:/|\z)}
  REPORT_CREATE = %r{\A/shows/[^/]+/reports\z}
  PITCH_CREATE = %r{\A/sponsor_matches/[^/]+/pitch\z}
  SHOW_SEARCH = %r{\A/shows/search\z}
  VERIFICATION = %r{\A/shows/([^/]+)/verification\z}
  JUDGE_CODE = %r{\A/account/judge_code\z}

  def self.post_to?(req, pattern) = req.post? && pattern.match?(req.route_path)
end

Rack::Attack.cache.store = RATE_LIMIT_STORE
Rack::Attack.enabled = !Rails.env.test?

Rack::Attack.throttle("requests per IP", limit: 60, period: 1.minute) do |req|
  req.ip unless RackAttackRules::UNCOUNTED_PATHS.match?(req.route_path)
end

# POST /shows/:show_id/reports
Rack::Attack.throttle("report creates per user", limit: 10, period: 1.hour) do |req|
  req.user_or_ip if RackAttackRules.post_to?(req, RackAttackRules::REPORT_CREATE)
end

# POST /sponsor_matches/:sponsor_match_id/pitch
Rack::Attack.throttle("pitch creates per user", limit: 30, period: 1.hour) do |req|
  req.user_or_ip if RackAttackRules.post_to?(req, RackAttackRules::PITCH_CREATE)
end

# GET or HEAD /shows/search (the add-a-show page's search as you type)
Rack::Attack.throttle("show searches per user", limit: 20, period: 1.minute) do |req|
  req.user_or_ip if req.read? && RackAttackRules::SHOW_SEARCH.match?(req.route_path)
end

# POST /shows/:show_id/verification with kind=email sends an ownership code. Keyed by the show and who asks, so
# requests naming someone else's show (a 404 anyway) can't use up its owner's sends. The id is read as the record
# lookup reads it, so "%31" and "01" are show 1 too.
Rack::Attack.throttle("verification code sends per show", limit: 5, period: 1.hour) do |req|
  match = req.post? && RackAttackRules::VERIFICATION.match(req.route_path)
  "#{Rack::Utils.unescape_path(match[1]).to_i}:#{req.user_or_ip}" if match && req.params["kind"] == "email"
end

# POST /account/judge_code: guesses at JUDGE_CODE, per user and per IP. AccountsController adds its own per-user limit.
Rack::Attack.throttle("judge code attempts per user", limit: 5, period: 1.hour) do |req|
  req.user_or_ip if RackAttackRules.post_to?(req, RackAttackRules::JUDGE_CODE)
end
Rack::Attack.throttle("judge code attempts per IP", limit: 5, period: 1.hour) do |req|
  req.ip if RackAttackRules.post_to?(req, RackAttackRules::JUDGE_CODE)
end

Rack::Attack.throttled_responder = ->(req) { ThrottledResponse.call(req) }
