require "resolv"

# Search engine crawlers, recognised the way Google, Bing and Apple tell sites to check them: a user agent that names
# the crawler is only a reason to look. The request's IP must reverse resolve to a host in the crawler's own domain,
# and that host must resolve forward to the same IP (anyone can set the reverse name of their own IP, but only the
# search engine controls its domain's forward records). A user agent alone, or a reverse name alone, never counts.
#
# ApplicationController asks only for GET and HEAD requests that are already past the global per-IP limit, so nearly
# every request skips this, and each answer is cached per IP (Rails.cache): a day when verified, 15 minutes when not
# (Resolv reports a DNS timeout as no answer, so a hiccup costs a real crawler no more than that). A lookup waits at
# most DNS_TIMEOUT seconds per query.
module VerifiedCrawler
  # A user agent pattern and the domains its reverse name must end in. Only domains the search engine alone
  # controls: never googleusercontent.com, which Google Cloud customers' own machines resolve to.
  CRAWLERS = [
    [ /Googlebot|Google-InspectionTool|GoogleOther|Storebot-Google/, %w[googlebot.com google.com].freeze ],
    [ /bingbot|msnbot|adidxbot|BingPreview/i, %w[search.msn.com].freeze ],
    [ /Applebot/, %w[applebot.apple.com].freeze ]
  ].freeze
  VERIFIED_FOR = 1.day
  UNVERIFIED_FOR = 15.minutes
  DNS_TIMEOUT = 1

  module_function

  # True for a GET or HEAD from a search engine's crawler, confirmed by DNS.
  def verified?(request)
    return false unless request.get? || request.head?

    domains = domains_for(request.user_agent)
    return false unless domains

    ip = request.remote_ip.to_s
    key = "verified_crawler:v1:#{domains.first}:#{ip}"
    cached = Rails.cache.read(key)
    return cached unless cached.nil?

    verified = confirmed?(ip, domains)
    Rails.cache.write(key, verified, expires_in: verified ? VERIFIED_FOR : UNVERIFIED_FOR)
    verified
  end

  def domains_for(user_agent)
    return nil if user_agent.blank?

    CRAWLERS.find { |pattern, _| user_agent.match?(pattern) }&.last
  end

  # The reverse lookup names a host in one of domains, and that host's forward lookup includes ip.
  def confirmed?(ip, domains)
    address = IPAddr.new(ip)
    Resolv::DNS.open do |dns|
      dns.timeouts = DNS_TIMEOUT
      name = reverse_name(dns, ip)
      next false unless name && domains.any? { |domain| name.end_with?(".#{domain}") }

      dns.getaddresses(name).any? { |found| IPAddr.new(found.to_s) == address }
    end
  rescue IPAddr::Error, Resolv::ResolvError, Resolv::ResolvTimeout, SocketError, SystemCallError, IOError
    false
  end

  # The PTR name, lower case and without the root's dot; nil when the IP has none.
  def reverse_name(dns, ip)
    dns.getname(ip).to_s.downcase.delete_suffix(".")
  rescue Resolv::ResolvError
    nil
  end
end
