module Podcasts
  module Directories
    class PodcastIndex
      BASE_URL = "https://api.podcastindex.org/api/1.0".freeze
      USER_AGENT = "Midrolo/1.0".freeze
      CACHE_TTL = 24.hours

      def initialize(key:, secret:, cache: Rails.cache)
        @key = key
        @secret = secret
        @cache = cache
      end

      def search(term, limit: 10)
        return [] if term.to_s.strip.empty?

        json = get("/search/byterm", q: term.to_s.strip, max: limit)
        Array(json && json["feeds"]).filter_map { |f| to_show(f) }
      end

      def find(directory_id)
        lookup("/podcasts/byfeedid", id: directory_id.to_s)
      end

      def find_by_feed_url(url)
        lookup("/podcasts/byfeedurl", url: url.to_s)
      end

      def find_by_itunes_id(itunes_id)
        lookup("/podcasts/byitunesid", id: itunes_id.to_s)
      end

      private

      def lookup(path, params)
        json = get(path, params)
        feed = json && json["feed"]
        feed.is_a?(Hash) && feed.any? ? to_show(feed) : nil
      end

      # Returns the parsed JSON body, or nil for a 404. Raises Directory::Unavailable on auth errors,
      # 5xx, timeouts and unparseable bodies. Failures are logged and never cached.
      def get(path, params)
        key = "podcasts:podcast_index:v1:#{path}:#{params.sort.to_h.to_query}"
        cached = @cache.read(key)
        return cached if cached

        response = connection.get("#{BASE_URL}#{path}", params, auth_headers)
        return nil if response.status == 404
        unavailable!(path, "returned HTTP #{response.status}") unless response.status == 200

        json = JSON.parse(response.body)
        @cache.write(key, json, expires_in: CACHE_TTL)
        json
      rescue Faraday::Error => e
        unavailable!(path, "failed: #{e.class}: #{e.message}")
      rescue JSON::ParserError
        unavailable!(path, "returned an unparseable body")
      end

      def unavailable!(path, detail)
        message = "Podcast Index #{path} #{detail}"
        Rails.logger.warn("[PodcastIndex] #{message}")
        raise Directory::Unavailable, message
      end

      def connection
        @connection ||= Http.build(headers: { "User-Agent" => USER_AGENT })
      end

      def auth_headers
        date = Time.now.to_i.to_s
        {
          "X-Auth-Key" => @key,
          "X-Auth-Date" => date,
          "Authorization" => Digest::SHA1.hexdigest(@key + @secret + date)
        }
      end

      def to_show(feed)
        ShowInfo.new(
          directory_id: feed["id"].to_s,
          title: feed["title"].to_s,
          author: feed["author"].to_s,
          description: feed["description"].to_s,
          artwork_url: feed["artwork"].presence || feed["image"].presence,
          feed_url: feed["url"].to_s,
          categories: (feed["categories"].is_a?(Hash) ? feed["categories"].values : []).map(&:to_s),
          episode_count: feed["episodeCount"],
          itunes_id: feed["itunesId"]&.to_s,
          language: feed["language"]
        )
      end
    end
  end
end
