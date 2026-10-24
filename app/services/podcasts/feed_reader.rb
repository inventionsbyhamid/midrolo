module Podcasts
  # Reads a podcast RSS feed. Never raises for feed problems: failures come back as a Feed with no
  # episodes and a warning code (feed_unreadable, feed_timeout, feed_too_large).
  class FeedReader
    MAX_BYTES = 5 * 1024 * 1024
    TIMEOUT = Http::TIMEOUT
    CACHE_TTL = 24.hours
    MAX_REDIRECTS = 3
    DESCRIPTION_LIMIT = 600
    # Block elements become line breaks, so "<p>Sponsored by Notion</p><p>Visit Today</p>" doesn't run together.
    BLOCK_TAGS = "p, div, li, ul, ol, h1, h2, h3, h4, h5, h6, tr, blockquote".freeze
    USER_AGENT = "Midrolo/1.0".freeze
    EMAIL_RE = /[^\s<>()@,;]+@[^\s<>()@,;]+\.[^\s<>()@,;]+/

    class TooLarge < StandardError; end

    def initialize(cache: Rails.cache)
      @cache = cache
    end

    # description_limit caps each episode description (characters); the proven-sponsor scan reads deeper.
    def read(feed_url, max_episodes: 20, description_limit: DESCRIPTION_LIMIT)
      url = feed_url.to_s.strip
      return fake_feed(url, max_episodes) if url.start_with?(Directories::Fake::FEED_PREFIX)
      return Feed.unreadable("feed_blocked") if SafeUrl.blocked?(url)

      key = "podcasts:feed:v2:#{max_episodes}:#{description_limit}:#{url}"
      cached = @cache.read(key)
      return cached if cached

      feed = fetch_and_parse(url, max_episodes, description_limit)
      @cache.write(key, feed, expires_in: CACHE_TTL) if feed.warnings.empty?
      feed
    rescue StandardError => e
      Rails.logger.warn("[FeedReader] unexpected #{e.class}: #{e.message}")
      Feed.unreadable
    end

    private

    def fake_feed(url, max_episodes)
      feed = Directories::Fake.feed_for(url.delete_prefix(Directories::Fake::FEED_PREFIX))
      return Feed.unreadable unless feed

      feed.with(episodes: feed.episodes.first(max_episodes))
    end

    def fetch_and_parse(url, max_episodes, description_limit)
      body = download(url)
      return body if body.is_a?(Feed)

      parse(to_utf8(body), max_episodes, description_limit)
    rescue TooLarge
      Feed.unreadable("feed_too_large")
    rescue Faraday::Error => e
      Feed.unreadable(timeout?(e) ? "feed_timeout" : "feed_unreadable")
    end

    # Net::HTTP reports a connect timeout as ConnectionFailed caused by Net::OpenTimeout.
    def timeout?(error)
      error.is_a?(Faraday::TimeoutError) || error.cause.is_a?(Net::OpenTimeout) || error.cause.is_a?(Net::ReadTimeout)
    end

    # Returns the body string, or a Feed when the response was not usable.
    def download(url)
      (MAX_REDIRECTS + 1).times do
        return Feed.unreadable("feed_blocked") if SafeUrl.blocked?(url)

        response, body = fetch(url)
        case response.status
        when 200 then return body
        when 301, 302, 303, 307, 308
          location = response.headers["location"].to_s
          url = URI.join(url, location).to_s rescue (return Feed.unreadable)
        else return Feed.unreadable
        end
      end
      Feed.unreadable
    end

    # Streams the response, aborting as soon as the size or time budget is exceeded.
    def fetch(url)
      buffer = +"".b
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = connection.get(url) do |req|
        req.options.on_data = proc do |chunk, received|
          buffer.clear if received <= chunk.bytesize # a retry restarts the stream
          raise TooLarge if received > MAX_BYTES
          raise Faraday::TimeoutError, "feed download exceeded #{TIMEOUT}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > TIMEOUT

          buffer << chunk
        end
      end
      [ response, buffer ]
    end

    def connection
      @connection ||= Http.build(headers: { "User-Agent" => USER_AGENT, "Accept" => "application/rss+xml, application/xml, text/xml, */*" })
    end

    def parse(xml, max_episodes, description_limit)
      parsed = Feedjira.parse(xml)
      doc = Nokogiri::XML(xml)
      doc.remove_namespaces!
      owner_name = doc.at_xpath("//channel/owner/name")&.text&.strip.presence ||
                   doc.at_xpath("//channel/author")&.text&.strip.presence
      episodes = parsed.entries.first(max_episodes).map { |e| episode(e, description_limit) }
      Feed.new(
        title: clean_line(parsed.title),
        description: clean(parsed.respond_to?(:description) ? parsed.description : nil),
        owner_email: owner_email(doc),
        owner_name: owner_name,
        episodes: episodes,
        cadence_days: cadence(episodes),
        warnings: []
      )
    rescue Feedjira::NoParserAvailable, Nokogiri::XML::SyntaxError
      Feed.unreadable
    end

    def episode(entry, description_limit)
      raw = [ entry.try(:content), entry.try(:summary), entry.try(:itunes_summary), entry.try(:itunes_subtitle) ].find(&:present?)
      EpisodeInfo.new(title: clean_line(entry.title).to_s, description: clean(raw, description_limit).to_s,
                      published_at: entry.published, guid: entry.entry_id.to_s.presence)
    end

    def owner_email(doc)
      candidates = [
        doc.at_xpath("//channel/owner/email")&.text,
        doc.at_xpath("//channel/email")&.text, # podcast:email, namespaces removed
        doc.at_xpath("//channel/managingEditor")&.text
      ]
      candidates.filter_map { |c| c.to_s[EMAIL_RE] }.first
    end

    def cadence(episodes)
      dates = episodes.filter_map(&:published_at).sort.reverse
      gaps = dates.each_cons(2).map { |a, b| (a - b) / 86_400.0 }
      return nil if gaps.empty?

      sorted = gaps.sort
      mid = sorted.size / 2
      median = sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
      median.round
    end

    # HTML to plain text. <br> and block elements become line breaks; other whitespace collapses to one space.
    def clean(html, limit = DESCRIPTION_LIMIT)
      return nil if html.nil?

      fragment = Nokogiri::HTML.fragment(html.to_s)
      fragment.css("br").each { |node| node.replace("\n") }
      fragment.css(BLOCK_TAGS).each do |node|
        node.before("\n")
        node.after("\n")
      end
      text = fragment.text.gsub(/[^\S\n]+/, " ").gsub(/\s*\n\s*/, "\n").strip
      text.truncate(limit)
    end

    # Single-line text, for titles.
    def clean_line(html) = clean(html)&.squish

    def to_utf8(bytes)
      raw = bytes.b.sub(/\A\xEF\xBB\xBF/n, "")
      declared = raw[/\A\s*<\?xml[^>]*encoding=["']([\w.-]+)["']/in, 1]
      encoding = (Encoding.find(declared) if declared) rescue nil
      if encoding && encoding != Encoding::UTF_8
        text = raw.dup.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        return text.sub(/(\A\s*<\?xml[^>]*encoding=["'])[\w.-]+/i, '\1UTF-8')
      end

      text = raw.dup.force_encoding(Encoding::UTF_8)
      return text if text.valid_encoding?

      raw.dup.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end
  end
end
