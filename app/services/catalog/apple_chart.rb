module Catalog
  # Apple's public podcast endpoints, for Catalog::SeedFromCharts (no key needed): the legacy Top Podcasts chart
  # (itunes.apple.com/{country}/rss/toppodcasts, at most 200 shows, all genres or one) and the lookup API, which gives a
  # show's feed URL by its Apple id. The newer rss.marketingtools.apple.com chart was answering 504 when this was built,
  # so the legacy one is read.
  #
  # Every fetch goes through Podcasts::SafeUrl (vetted, then pinned, every redirect hop too) with a byte cap and one
  # deadline. Only the Apple id, name and artist are read from the chart and only the feed URL from the lookup; the
  # rest comes from the show's own feed. Raises Unavailable when Apple doesn't answer usefully.
  #
  #   Catalog::AppleChart.top(country: "us", limit: 200, genre: "1318") # => [Entry, ...], chart order
  #   Catalog::AppleChart.feed_url("1200361736")                        # => "https://...", or nil when Apple has none
  module AppleChart
    class Unavailable < StandardError; end

    Entry = Data.define(:apple_id, :name, :artist)

    BASE_URL = "https://itunes.apple.com".freeze
    MAX_LIMIT = 200
    MAX_BYTES = 2 * 1024 * 1024 # the full chart of 200 is about 450 KB
    TIMEOUT = 20 # seconds for one fetch, redirects included
    MAX_REDIRECTS = 3
    REDIRECTS = [ 301, 302, 303, 307, 308 ].freeze
    COUNTRY = /\A[a-z]{2}\z/
    APPLE_ID = /\A\d{1,18}\z/
    USER_AGENT = "Midrolo/1.0".freeze

    class << self
      # The chart's shows in rank order, one per Apple id. country is a two letter store code, genre an Apple genre id
      # (nil for every genre).
      def top(country: "us", limit: MAX_LIMIT, genre: nil)
        country = country.to_s.downcase
        raise ArgumentError, "country must be a two letter store code, like us" unless country.match?(COUNTRY)
        raise ArgumentError, "limit must be 1 to #{MAX_LIMIT}" unless limit.is_a?(Integer) && limit.between?(1, MAX_LIMIT)
        raise ArgumentError, "genre must be an Apple genre id, like 1318" unless genre.nil? || genre.to_s.match?(APPLE_ID)

        url = [ "#{BASE_URL}/#{country}/rss/toppodcasts/limit=#{limit}", ("genre=#{genre}" if genre), "json" ].compact.join("/")
        feed = get_json(url)["feed"]
        entries = feed.is_a?(Hash) ? feed["entry"] : nil
        entries = [ entries ] if entries.is_a?(Hash) # a chart of one isn't a list
        Array(entries).filter_map { |raw| parse_entry(raw) }.uniq(&:apple_id)
      end

      # The feed URL Apple lists for a show, or nil when Apple doesn't know the show or lists no http(s) feed for it.
      def feed_url(apple_id)
        id = apple_id.to_s
        raise ArgumentError, "not an Apple id: #{apple_id.inspect}" unless id.match?(APPLE_ID)

        results = get_json("#{BASE_URL}/lookup?id=#{id}&entity=podcast")["results"]
        show = Array(results).find { |result| result.is_a?(Hash) && result["kind"] == "podcast" && result["collectionId"].to_s == id }
        url = show && show["feedUrl"].to_s.strip
        url if url&.match?(%r{\Ahttps?://\S+\z}i)
      end

      private

      def parse_entry(raw)
        return unless raw.is_a?(Hash)

        id = raw.dig("id", "attributes", "im:id").to_s
        name = raw.dig("im:name", "label").to_s.squish
        return unless id.match?(APPLE_ID) && name.present?

        Entry.new(apple_id: id, name: name, artist: raw.dig("im:artist", "label").to_s.squish.presence)
      end

      def get_json(url)
        json = JSON.parse(fetch(url))
        json.is_a?(Hash) ? json : raise(Unavailable, "Apple answered #{url} with JSON that isn't an object")
      rescue JSON::ParserError
        raise Unavailable, "Apple answered #{url} with something that isn't JSON"
      end

      # The body of a 200, following up to MAX_REDIRECTS redirects, each hop vetted and pinned.
      def fetch(url)
        deadline = now + TIMEOUT
        (MAX_REDIRECTS + 1).times do
          target = Podcasts::SafeUrl.resolve!(url)
          response, body = get(target, deadline)
          return body if response.status == 200
          raise Unavailable, "Apple answered #{url} with HTTP #{response.status}" unless REDIRECTS.include?(response.status)

          url = URI.join(url, response.headers["location"].to_s).to_s
        end
        raise Unavailable, "too many redirects from Apple"
      rescue Podcasts::SafeUrl::Blocked, Faraday::Error, URI::InvalidURIError => e
        raise Unavailable, "Apple fetch failed: #{e.class}: #{e.message}"
      end

      # One hop. The body is checked against the cap and the deadline as it streams.
      def get(target, deadline)
        body = +"".b
        response = connection(target).get(target.uri.to_s) do |request|
          request.options.on_data = proc do |chunk, received|
            body.clear if received <= chunk.bytesize # a retry restarts the stream
            raise Unavailable, "Apple's answer is over #{MAX_BYTES} bytes" if received > MAX_BYTES
            raise Unavailable, "Apple took over #{TIMEOUT}s" if now > deadline

            body << chunk
          end
        end
        [ response, body.force_encoding(Encoding::UTF_8) ]
      end

      def connection(target)
        Podcasts::Http.build(headers: { "User-Agent" => USER_AGENT, "Accept" => "application/json" }, pin: target)
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
