require "timeout"
require "zlib"

module Catalog
  # Fetches a podcast feed for ingest: a conditional GET (ETag, Last-Modified) through Podcasts::SafeUrl (every hop
  # vetted, then pinned to the address it was vetted at), gzip read, at most 15 MB, one deadline for the whole fetch,
  # redirect loops caught. Never raises: a problem comes back as an error code the podcast keeps in last_error.
  #
  # A feed over the cap is cut after its last whole episode and closed, since feeds list the newest first (a 22 MB
  # back catalog still has its newest 50 at the top); one with no whole episode in the cap is "feed_too_large".
  #
  # The demo directory's fake:// feeds (Podcasts::Directories::Fake) are made up locally, so development and specs
  # ingest them without the network.
  class FeedFetcher
    MAX_BYTES = 15.megabytes
    TOTAL_TIMEOUT = 30 # seconds, redirects included
    OPEN_TIMEOUT = 5
    MAX_REDIRECTS = 5
    REDIRECTS = [ 301, 302, 303, 307, 308 ].freeze
    PERMANENT = [ 301, 308 ].freeze
    USER_AGENT = "Midrolo/1.0 (+https://midrolo.com)".freeze
    ACCEPT = "application/rss+xml, application/xml;q=0.9, text/xml;q=0.9, */*;q=0.5".freeze
    GZIP = "\x1F\x8B".b.freeze
    STATUS_ERRORS = { 401 => "feed_forbidden", 403 => "feed_forbidden", 404 => "feed_not_found", 410 => "feed_gone",
                      429 => "feed_rate_limited" }.freeze

    class TooLarge < StandardError
      attr_reader :partial

      def initialize(partial)
        @partial = partial
        super("feed over #{MAX_BYTES} bytes")
      end
    end

    class TooSlow < StandardError; end
    # Over the cap with no whole episode in what came.
    class NoWholeItem < StandardError; end
    # One hop's answer: a status, its headers and the body read (truncated when cut at the cap).
    Hop = Data.define(:status, :headers, :body, :truncated)

    # status is :ok (body set), :not_modified or :error (error set). moved_to is the URL a chain of permanent redirects
    # ended at, when every hop was permanent.
    Result = Data.define(:status, :body, :etag, :last_modified, :sha256, :moved_to, :truncated, :error) do
      def self.error(code) = new(status: :error, body: nil, etag: nil, last_modified: nil, sha256: nil, moved_to: nil,
                                 truncated: false, error: code)

      def ok? = status == :ok
      def not_modified? = status == :not_modified
      def error? = status == :error
    end

    def self.call(url, etag: nil, last_modified: nil) = new(url, etag, last_modified).call

    def initialize(url, etag, last_modified)
      @url = url.to_s.strip
      @etag = etag.presence
      @last_modified = last_modified.presence
    end

    def call
      return fake if @url.start_with?(Podcasts::Directories::Fake::FEED_PREFIX)

      deadline = now + TOTAL_TIMEOUT
      Timeout.timeout(TOTAL_TIMEOUT, TooSlow) { follow(deadline) }
    rescue Podcasts::SafeUrl::Blocked
      Result.error("feed_blocked")
    rescue TooSlow, Faraday::TimeoutError
      Result.error("feed_timeout")
    rescue NoWholeItem
      Result.error("feed_too_large")
    rescue Faraday::SSLError
      Result.error("feed_tls_error")
    rescue Faraday::Error => e
      Result.error(e.cause.is_a?(Net::OpenTimeout) || e.cause.is_a?(Net::ReadTimeout) ? "feed_timeout" : "feed_unreachable")
    rescue Zlib::Error
      Result.error("feed_unreadable")
    rescue StandardError => e
      Rails.logger.warn("[Catalog::FeedFetcher] #{e.class}: #{e.message}")
      Result.error("feed_unreadable")
    end

    private

    def follow(deadline)
      url = @url
      seen = []
      permanent = true
      (MAX_REDIRECTS + 1).times do
        return Result.error("feed_redirect_loop") if seen.include?(url)

        seen << url
        hop = get(Podcasts::SafeUrl.resolve!(url), deadline)
        return finished(hop, (url if permanent && seen.size > 1)) if hop.status == 200
        return not_modified(hop) if hop.status == 304
        return Result.error(error_for(hop.status)) unless REDIRECTS.include?(hop.status)

        permanent &&= PERMANENT.include?(hop.status)
        location = hop.headers["location"].to_s.strip
        return Result.error("feed_unreadable") if location.empty?

        url = URI.join(url, location).to_s
      end
      Result.error("feed_too_many_redirects")
    rescue URI::Error
      Result.error("feed_unreadable")
    end

    # One hop, its timeouts from what's left of the deadline. The body is checked against the cap and the deadline as
    # it streams; past the cap, what came so far is kept and closed after its last whole item.
    def get(target, deadline)
      left = deadline - now
      raise TooSlow unless left.positive?

      buffer = +"".b
      response = connection(target, left).get(target.uri.to_s) do |request|
        request.headers["If-None-Match"] = @etag if @etag
        request.headers["If-Modified-Since"] = @last_modified if @last_modified
        request.options.on_data = proc do |chunk, received|
          raise TooSlow if now > deadline
          raise TooLarge, buffer << chunk.byteslice(0, chunk.bytesize - (received - MAX_BYTES)) if received > MAX_BYTES

          buffer << chunk
        end
      end
      Hop.new(status: response.status, headers: response.headers, body: buffer, truncated: false)
    rescue TooLarge => e
      # Streaming stopped mid-body, so the response's headers are gone with it (no ETag: the digest still skips a parse).
      Hop.new(status: 200, headers: {}, body: close_after_last_item(e.partial) || raise(NoWholeItem), truncated: true)
    end

    def finished(hop, moved_to)
      body, truncated = hop.body.start_with?(GZIP) ? gunzip(hop.body) : [ hop.body, hop.truncated ]
      return Result.error("feed_empty") if body.strip.empty?

      Result.new(status: :ok, body: body, etag: header(hop, "etag"), last_modified: header(hop, "last-modified"),
                 sha256: Digest::SHA256.hexdigest(body), moved_to: moved_to, truncated: truncated, error: nil)
    end

    def not_modified(hop)
      Result.new(status: :not_modified, body: nil, etag: header(hop, "etag") || @etag,
                 last_modified: header(hop, "last-modified") || @last_modified, sha256: nil, moved_to: nil,
                 truncated: false, error: nil)
    end

    def error_for(status)
      STATUS_ERRORS[status] || (status >= 500 ? "feed_server_error" : "feed_http_#{status}")
    end

    def header(hop, name) = hop.headers[name].to_s.strip.first(255).presence

    # [body, truncated] for a body that arrived still gzipped (Net::HTTP inflates only what it asked for and was told
    # about), inflated under the same cap.
    def gunzip(body)
      reader = Zlib::GzipReader.new(StringIO.new(body))
      out = +"".b
      while (chunk = reader.read(64.kilobytes))
        out << chunk
        return [ close_after_last_item(out.byteslice(0, MAX_BYTES)) || raise(NoWholeItem), true ] if out.bytesize > MAX_BYTES
      end
      [ out, false ]
    ensure
      reader&.close
    end

    # The feed's first bytes cut after its last whole item and closed, so it parses; nil without a whole one.
    def close_after_last_item(partial)
      cut = partial.rindex("</item>".b)
      partial.byteslice(0, cut + "</item>".bytesize) + "</channel></rss>" if cut
    end

    # One per hop: it reaches only that hop's vetted address. Net::HTTP asks for gzip and inflates it while streaming,
    # so the cap counts the inflated bytes.
    def connection(target, left)
      Faraday.new(headers: { "User-Agent" => USER_AGENT, "Accept" => ACCEPT }) do |faraday|
        faraday.options.timeout = left
        faraday.options.open_timeout = [ OPEN_TIMEOUT, left ].min
        Podcasts::SafeUrl.pin(faraday, target)
      end
    end

    def fake
      xml = FakeFeed.xml(@url.delete_prefix(Podcasts::Directories::Fake::FEED_PREFIX))
      return Result.error("feed_not_found") unless xml

      Result.new(status: :ok, body: xml, etag: nil, last_modified: nil, sha256: Digest::SHA256.hexdigest(xml),
                 moved_to: nil, truncated: false, error: nil)
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
