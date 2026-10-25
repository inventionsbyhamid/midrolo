# Who the client is (request.remote_ip, which the per-IP rate limits and Devise's sign-in tracking read). In
# production Traefik (on the Docker network) and Thruster (in the web container) sit in front of Puma, both on private
# addresses Rails trusts, and each appends the address it heard from to X-Forwarded-For. With Cloudflare's proxy on, a
# Cloudflare edge server comes first; cloudflare-rails adds Cloudflare's ranges to the trusted proxies.

# Which header says who the client is (R83). Behind our proxy (Traefik, on a private address Rack trusts), Rack reads
# the Forwarded header before X-Forwarded-For by default, and the proxy passes a client's own Forwarded header through
# untouched: anyone could pick their own IP (and with it their per-IP rate-limit bucket), host and scheme. Read only
# the X-Forwarded-* headers, which the proxy writes. This covers ActionDispatch's remote_ip as well as Rack's ip:
# Rails' RemoteIp middleware takes its list from Rack's forwarded_for, which follows this setting.
Rack::Request.forwarded_priority = [ :x_forwarded ]

module ClientIp
  # Traefik drops the X-Forwarded-For of a peer it doesn't trust (its default, and Cloudflare isn't on its list) and
  # writes only the edge server it heard from, so remote_ip would be Cloudflare's. Cloudflare names the client in
  # CF-Connecting-IP. It's believed only when the nearest hop that isn't one of our own proxies is a Cloudflare
  # address, which a client can't fake: Traefik writes that hop from the connection itself. The chain then reads
  # client, edge, Traefik, and RemoteIp takes the client.
  class CloudflareClient
    def initialize(app)
      @app = app
    end

    def call(env)
      client = ip(env["HTTP_CF_CONNECTING_IP"])
      if client
        hops = env["HTTP_X_FORWARDED_FOR"].to_s.split(",").map(&:strip)
        nearest = hops.rindex { |hop| !own_proxy?(ip(hop)) }
        if nearest && cloudflare?(ip(hops[nearest]))
          env["HTTP_X_FORWARDED_FOR"] = [ client.to_s, *hops[nearest..] ].join(", ")
        end
      end
      @app.call(env)
    end

    private

    def ip(value)
      IPAddr.new(value.to_s.strip)
    rescue IPAddr::Error
      nil
    end

    def own_proxy?(address) = address && ActionDispatch::RemoteIp::TRUSTED_PROXIES.any? { |range| range.include?(address) }

    def cloudflare?(address) = address && CloudflareRails::Importer.cloudflare_ips.any? { |range| range.include?(address) }
  end

  # Rails refuses to guess the client when a Client-IP header disagrees with X-Forwarded-For: remote_ip raises
  # IpSpoofAttackError (Task 18b review). The proxies in front of us don't send Client-IP, so a client did. The first
  # remote_ip call is Rails' own request log line, which runs before ShowExceptions, so the error would reach Puma as a
  # bare 500 and the admin as an error mail. This asks first and answers with the 400 page instead;
  # config/application.rb maps the error to 400 for anywhere else it could come from.
  class RejectConflictingHeaders
    def initialize(app)
      @app = app
    end

    def call(env)
      ActionDispatch::Request.new(env).remote_ip
    rescue ActionDispatch::RemoteIp::IpSpoofAttackError
      [ 400, { "content-type" => "text/html; charset=utf-8" }, [ Rails.public_path.join("400.html").read ] ]
    else
      @app.call(env)
    end
  end
end

Rails.application.config.middleware.insert_before ActionDispatch::RemoteIp, ClientIp::CloudflareClient
Rails.application.config.middleware.insert_after ActionDispatch::RemoteIp, ClientIp::RejectConflictingHeaders
