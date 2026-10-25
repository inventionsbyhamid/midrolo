# Rate limits (spec §9a, §11; R69). Counters live in Rails.cache (Solid Cache in production). In specs Rack::Attack is
# off, so suites that make many requests from 127.0.0.1 never see a 429; examples tagged :rack_attack turn it on over
# a MemoryStore (spec/support/rack_attack.rb). The 429 itself is ThrottledResponse.
#
# Per-IP limits key on req.ip (the client's address behind the proxies cloudflare-rails trusts). Per-user limits key on
# the signed-in user that Warden (which runs before Rack::Attack) found in the session, and on the IP when signed out.
# The verification and Rails rate_limit throttles in the controllers still apply on top of these.
module RackAttackRules
  # Never counted against the per-IP limit: static files, the health check, Action Cable, uploads, provider webhooks.
  UNCOUNTED_PATHS = %r{\A/(?:assets|up|cable|rails/active_storage|webhooks)(?:/|\z)}

  module_function

  def user_or_ip(req)
    user_id = req.env["warden"]&.user&.id
    user_id ? "user:#{user_id}" : "ip:#{req.ip}"
  end

  def post_to?(req, pattern) = req.post? && pattern.match?(req.path)
end

Rack::Attack.cache.store = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache
Rack::Attack.enabled = !Rails.env.test?

Rack::Attack.throttle("requests per IP", limit: 60, period: 1.minute) do |req|
  req.ip unless RackAttackRules::UNCOUNTED_PATHS.match?(req.path)
end

# POST /shows/:show_id/reports
Rack::Attack.throttle("report creates per user", limit: 10, period: 1.hour) do |req|
  RackAttackRules.user_or_ip(req) if RackAttackRules.post_to?(req, %r{\A/shows/[^/]+/reports/?\z})
end

# POST /sponsor_matches/:sponsor_match_id/pitch
Rack::Attack.throttle("pitch creates per user", limit: 30, period: 1.hour) do |req|
  RackAttackRules.user_or_ip(req) if RackAttackRules.post_to?(req, %r{\A/sponsor_matches/[^/]+/pitch/?\z})
end

# GET /shows/search (the add-a-show page's search as you type)
Rack::Attack.throttle("show searches per user", limit: 20, period: 1.minute) do |req|
  RackAttackRules.user_or_ip(req) if req.get? && %r{\A/shows/search/?\z}.match?(req.path)
end

# POST /shows/:show_id/verification with kind=email sends an ownership code. Keyed by the show and who asks, so
# requests naming someone else's show (a 404 anyway) can't use up its owner's sends.
Rack::Attack.throttle("verification code sends per show", limit: 5, period: 1.hour) do |req|
  match = %r{\A/shows/([^/]+)/verification/?\z}.match(req.path)
  "#{match[1]}:#{RackAttackRules.user_or_ip(req)}" if match && req.post? && req.params["kind"] == "email"
end

# POST /account/judge_code: guesses at JUDGE_CODE, per user and per IP.
Rack::Attack.throttle("judge code attempts per user", limit: 5, period: 1.hour) do |req|
  RackAttackRules.user_or_ip(req) if RackAttackRules.post_to?(req, %r{\A/account/judge_code/?\z})
end
Rack::Attack.throttle("judge code attempts per IP", limit: 5, period: 1.hour) do |req|
  req.ip if RackAttackRules.post_to?(req, %r{\A/account/judge_code/?\z})
end

Rack::Attack.throttled_responder = ->(req) { ThrottledResponse.call(req) }
