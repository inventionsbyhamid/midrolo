require "ipaddr"
require "resolv"

module Podcasts
  # SSRF guard for user-supplied URLs (feeds, show artwork): http(s) on ports 80/443 only, and the host must not resolve
  # to any internal address.
  #
  # A fetch resolves the host once (resolve!), checks every address, and then connects to a vetted one (pin): the
  # hostname stays the Host header, the TLS SNI and the name the certificate is verified against, and DNS isn't asked
  # again, so an answer that changes between the check and the connect (rebinding) can't move the request. This is what
  # keeps a fetch off other stacks' ports: midrolo-web shares Coolify's network with other production apps (R131).
  # Callers vet and pin every redirect hop the same way.
  module SafeUrl
    class Blocked < StandardError; end

    # A vetted URL: its URI and the address to connect to.
    Target = Data.define(:uri, :address)

    ALLOWED_PORTS = [ 80, 443 ].freeze
    # NAT64 (64:ff9b::/96, 64:ff9b:1::/48) and 6to4 (2002::/16) addresses embed an IPv4 one that a gateway may route to.
    BLOCKED_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24
      192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 fe80::/10 fc00::/7 ff00::/8 64:ff9b::/96 64:ff9b:1::/48 2002::/16
    ].map { |r| IPAddr.new(r) }.freeze

    module_function

    # Returns the URI when safe, raises Blocked otherwise.
    def check!(url) = resolve!(url).uri

    # Returns a Target: the URI, and the vetted address to connect to (an IPv4 one when the host has one). Raises
    # Blocked when the URL isn't safe.
    def resolve!(url)
      uri = URI.parse(url.to_s.strip)
      raise Blocked, "scheme not allowed" unless %w[http https].include?(uri.scheme&.downcase)
      raise Blocked, "missing host" if uri.host.blank?
      raise Blocked, "port not allowed" unless ALLOWED_PORTS.include?(uri.port)

      raise Blocked, "non-canonical host" unless canonical_host?(uri.host)

      addresses = addresses_for(uri.host).map { |a| a.ipv4_mapped? ? a.native : a }
      raise Blocked, "host does not resolve" if addresses.empty?
      raise Blocked, "internal address" if addresses.any? { |a| blocked_ip?(a) }

      Target.new(uri: uri, address: (addresses.find(&:ipv4?) || addresses.first).to_s)
    rescue URI::InvalidURIError
      raise Blocked, "invalid url"
    end

    # Sets a Faraday connection to send its requests to target's vetted address only: Net::HTTP connects to ipaddr
    # and keeps the URL's hostname for the Host header, SNI and the certificate check. A proxy from the environment is
    # turned off, since it would look the name up again.
    def pin(faraday, target)
      faraday.proxy = nil
      faraday.adapter(:net_http) { |http| http.ipaddr = target.address }
    end

    def blocked?(url)
      check!(url)
      false
    rescue Blocked
      true
    end

    OCTET = /(?:0|[1-9]\d{0,2})/
    DOTTED_QUAD = /\A#{OCTET}(?:\.#{OCTET}){3}\z/

    # Accepts only a canonical dotted-quad IPv4, an IPv6 literal, or a hostname with a letter in its final
    # label. Rejects decimal, hex, octal and short IPv4 forms (2130706433, 0x7f.1, 127.1, 0177.0.0.1) that
    # getaddrinfo would parse locally but Resolv would not.
    def canonical_host?(host)
      bare = host.delete_prefix("[").delete_suffix("]")
      return true if bare.include?(":")
      return bare.split(".").all? { |o| o.to_i <= 255 } if bare.match?(DOTTED_QUAD)

      bare.delete_suffix(".").split(".").last.to_s.match?(/[a-z]/i)
    end

    def addresses_for(host)
      bare = host.delete_prefix("[").delete_suffix("]")
      literal = (IPAddr.new(bare) rescue nil)
      return [ literal ] if literal

      Resolv.getaddresses(bare).filter_map { |a| IPAddr.new(a) rescue nil }
    rescue Resolv::ResolvError
      []
    end

    def blocked_ip?(ip)
      ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
      BLOCKED_RANGES.any? { |r| r.family == ip.family && r.include?(ip) }
    end
  end
end
