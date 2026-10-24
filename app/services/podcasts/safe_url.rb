require "ipaddr"
require "resolv"

module Podcasts
  # SSRF guard for user-supplied feed URLs: http(s) on ports 80/443 only, and the host must not resolve
  # to any internal address.
  module SafeUrl
    class Blocked < StandardError; end

    ALLOWED_PORTS = [ 80, 443 ].freeze
    BLOCKED_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24
      192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 fe80::/10 fc00::/7 ff00::/8
    ].map { |r| IPAddr.new(r) }.freeze

    module_function

    # Returns the URI when safe, raises Blocked otherwise.
    def check!(url)
      uri = URI.parse(url.to_s.strip)
      raise Blocked, "scheme not allowed" unless %w[http https].include?(uri.scheme&.downcase)
      raise Blocked, "missing host" if uri.host.blank?
      raise Blocked, "port not allowed" unless ALLOWED_PORTS.include?(uri.port)

      raise Blocked, "non-canonical host" unless canonical_host?(uri.host)

      addresses = addresses_for(uri.host)
      raise Blocked, "host does not resolve" if addresses.empty?
      raise Blocked, "internal address" if addresses.any? { |a| blocked_ip?(a) }

      uri
    rescue URI::InvalidURIError
      raise Blocked, "invalid url"
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
