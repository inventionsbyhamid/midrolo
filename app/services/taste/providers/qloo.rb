module Taste
  module Providers
    # Qloo REST adapter. All calls are GET; array params are joined with commas.
    class Qloo
      DEFAULT_BASE_URL = "https://hackathon.api.qloo.com".freeze
      CACHE_TTL = 7.days
      AFFINITY_CHUNK = 50
      TIMEOUT = 20
      OPEN_TIMEOUT = 5
      ATTEMPTS = 3
      RETRY_STATUSES = [ 429, 500, 502, 503, 504 ].freeze
      AGE_BUCKETS = %w[24_and_younger 25_to_29 30_to_34 35_to_44 45_to_54 55_and_older].freeze

      def initialize(api_key:, base_url: ENV.fetch("QLOO_BASE_URL", DEFAULT_BASE_URL), cache: Rails.cache, retry_interval: 0.5)
        @api_key = api_key
        @base_url = base_url.to_s.chomp("/")
        @cache = cache
        @retry_interval = retry_interval
      end

      def search(query:, types:, take: 5)
        params = { "query" => query, "types" => Array(types).map { |t| Provider.urn_for(t) }, "take" => take }
        entities(get("/search", params))
      end

      def find_tags(query:, take: 10)
        tags(get("/v2/tags", { "filter.query" => query, "feature.semantic_search" => true, "take" => take }))
      end

      def recommend(type:, entity_ids: [], tag_ids: [], filter_tags: [], popularity_max: nil, take: 20)
        params = { "filter.type" => Provider.urn_for(type), "filter.tags" => filter_tags,
                   "filter.popularity.max" => popularity_max, "take" => take }.merge(signals(entity_ids, tag_ids))
        entities(get("/v2/insights", params))
      end

      # Qloo has no batch-affinity endpoint: scope insights to the candidates with filter.results.entities,
      # in chunks of 50. Every candidate id is a key; nil means Qloo returned no score for it.
      def affinity_for(candidate_ids:, entity_ids: [], tag_ids: [], type: :brand)
        ids = Array(candidate_ids).map(&:to_s)
        result = ids.to_h { |id| [ id, nil ] }
        ids.each_slice(AFFINITY_CHUNK) do |chunk|
          params = { "filter.type" => Provider.urn_for(type), "filter.results.entities" => chunk,
                     "take" => chunk.size }.merge(signals(entity_ids, tag_ids))
          entities(get("/v2/insights", params)).each { |e| result[e.id] = e.affinity if chunk.include?(e.id) }
        end
        result
      end

      def taste_tags(entity_ids: [], tag_ids: [], take: 20)
        tags(get("/v2/insights", { "filter.type" => "urn:tag", "take" => take }.merge(signals(entity_ids, tag_ids))))
      end

      def demographics(entity_ids: [], tag_ids: [])
        json = get("/v2/insights", { "filter.type" => "urn:demographics" }.merge(signals(entity_ids, tag_ids)))
        query = Array(dig_results(json, "demographics")).first&.dig("query") || {}
        Demographics.new(age: leans(query["age"]), gender: leans(query["gender"]))
      end

      def heatmap(location:, entity_ids: [], tag_ids: [], take: 50)
        params = { "filter.type" => "urn:heatmap", "filter.location.query" => location,
                   "output.heatmap.boundary" => "urn:entity:locality", "take" => take }.merge(signals(entity_ids, tag_ids))
        Array(dig_results(get("/v2/insights", params), "heatmap")).filter_map { |h| heat_point(h) }
      end

      def compare(a_entity_ids:, b_entity_ids:, take: 10)
        params = { "a.signal.interests.entities" => a_entity_ids, "b.signal.interests.entities" => b_entity_ids, "take" => take }
        tags(get("/v2/analysis/compare", params))
      end

      private

      def signals(entity_ids, tag_ids)
        out = { "signal.interests.entities" => entity_ids, "signal.interests.tags" => tag_ids }
        out["operator.signal.interests.tags"] = "union" if Array(tag_ids).size > 1
        out
      end

      # ---- HTTP ----

      def get(path, params)
        params = normalize(params)
        key = cache_key(path, params)
        started = monotonic
        if (cached = @cache.read(key))
          notify(path, true, 200, started)
          return cached
        end

        response = connection.get(path, params)
        status = response.status
        notify(path, false, status, started)
        raise_for_status!(path, response)

        json = parse(path, response.body)
        @cache.write(key, json, expires_in: CACHE_TTL)
        json
      rescue Faraday::Error => e
        notify(path, false, nil, started)
        unavailable!(path, "failed: #{e.class}: #{e.message}")
      end

      def normalize(params)
        params.each_with_object({}) do |(k, v), out|
          v = Array(v).join(",") if v.is_a?(Array)
          out[k] = v.to_s unless v.nil? || v.to_s.empty?
        end
      end

      def cache_key(path, params)
        "taste:v1:#{Digest::SHA256.hexdigest("#{path}?#{params.sort.to_h.to_query}")}"
      end

      def raise_for_status!(path, response)
        case response.status
        when 200..299 then nil
        when 401, 403 then fail_with(AuthError, path, response)
        when 429 then fail_with(RateLimited, path, response)
        when 500..599 then fail_with(Unavailable, path, response)
        else fail_with(Error, path, response)
        end
      end

      def fail_with(klass, path, response)
        detail = begin
          JSON.parse(response.body.to_s)["message"]
        rescue JSON::ParserError, TypeError
          nil
        end
        message = "Qloo #{path} returned HTTP #{response.status}#{": #{detail}" if detail}"
        Rails.logger.warn("[Qloo] #{message}")
        raise klass, message
      end

      def parse(path, body)
        json = JSON.parse(body.to_s)
        return json if json.is_a?(Hash)

        unavailable!(path, "returned an unexpected body")
      rescue JSON::ParserError
        unavailable!(path, "returned an unparseable body")
      end

      def unavailable!(path, detail)
        message = "Qloo #{path} #{detail}"
        Rails.logger.warn("[Qloo] #{message}")
        raise Unavailable, message
      end

      def notify(path, cached, status, started)
        ActiveSupport::Notifications.instrument("request.taste", path: path, cached: cached, status: status,
                                                                  duration_ms: ((monotonic - started) * 1000).round(1))
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def connection
        @connection ||= Faraday.new(url: @base_url, headers: { "X-Api-Key" => @api_key, "Accept" => "application/json" }) do |f|
          f.request :retry, max: ATTEMPTS - 1, interval: @retry_interval, max_interval: 10, retry_statuses: RETRY_STATUSES,
                            methods: %i[get], exceptions: [ Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::RetriableResponse ]
          f.options.timeout = TIMEOUT
          f.options.open_timeout = OPEN_TIMEOUT
          f.adapter Faraday.default_adapter
        end
      end

      # ---- mapping (docs are inconsistent, so every rule is tolerant and lives here once) ----

      def dig_results(json, key)
        results = json["results"]
        results.is_a?(Hash) ? results[key] : nil
      end

      def entities(json)
        results = json["results"]
        list = results.is_a?(Hash) ? results["entities"] : results
        Array(list).filter_map { |e| entity(e) if e.is_a?(Hash) }
      end

      def entity(e)
        props = e["properties"].is_a?(Hash) ? e["properties"] : {}
        urn = e["subtype"] || Array(e["types"]).first
        Entity.new(
          id: (e["entity_id"] || e["id"]).to_s, name: e["name"].to_s, type: Provider.type_for(urn) || urn,
          popularity: float(e["popularity"]), affinity: float(e.dig("query", "affinity") || e["affinity"]),
          image_url: props.dig("image", "url").presence, description: props["description"].presence,
          website: (props["official_site"] || e["official_site"] || Array(props["websites"]).first).presence,
          tags: Array(e["tags"]).filter_map { |t| tag(t) if t.is_a?(Hash) }, properties: props
        )
      end

      def tags(json)
        results = json["results"]
        list = results.is_a?(Hash) ? results["tags"] : results
        Array(list).filter_map { |t| tag(t) if t.is_a?(Hash) }
      end

      def tag(t)
        Tag.new(id: (t["id"] || t["tag_id"]).to_s, name: t["name"].to_s, type: t["type"] || t["subtype"],
                score: float(t.dig("query", "score") || t.dig("query", "affinity") || t["score"]))
      end

      def heat_point(h)
        loc = h["location"] || {}
        query = h["query"] || {}
        return nil unless loc["latitude"] && loc["longitude"]

        HeatPoint.new(lat: float(loc["latitude"]), lng: float(loc["longitude"]), geohash: loc["geohash"],
                      affinity: float(query["affinity"]), popularity: float(query["popularity"]),
                      label: (loc["name"] || loc["city"] || loc["locality"]).presence)
      end

      def leans(hash)
        (hash.is_a?(Hash) ? hash : {}).transform_values { |v| float(v) }
      end

      def float(value)
        value.nil? ? nil : Float(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
