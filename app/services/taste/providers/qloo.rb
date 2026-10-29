module Taste
  module Providers
    # Qloo REST adapter. All calls are GET; array params are joined with commas. Reading the answers into value objects
    # is Qloo::Mapping's job.
    #
    # Call discipline (R92): answers are cached and shared by every report; an uncached request takes a slot from the
    # call guard (Taste::CallGuard) before each attempt, and is tried at most twice. A 429 is retried once only when
    # its Retry-After is MAX_RETRY_AFTER seconds or less, a 5xx or a timeout once after a short backoff, any other 4xx
    # never.
    class Qloo
      DEFAULT_BASE_URL = "https://hackathon.api.qloo.com".freeze
      # R93: lookups by name and tag lookups barely change, so they keep longer; every other answer 7 days.
      CACHE_TTL = 7.days
      STABLE_CACHE_TTL = 30.days
      STABLE_PATHS = %w[/search /v2/tags].freeze
      # R110: a 400 or 404 answers the same params the same way, so it is remembered for a day, as a miss marker.
      MISS_TTL = 1.day
      MISS_KEY = "qloo_miss_status".freeze
      MISSES = { 400 => BadRequest, 404 => NotFound }.freeze
      AFFINITY_CHUNK = 50
      # Qloo ignores take on heatmaps (8,421 points for the United States, R106): only this many are kept and cached.
      HEATMAP_KEEP = 200
      TIMEOUT = 20
      OPEN_TIMEOUT = 5
      ATTEMPTS = 2
      MAX_RETRY_AFTER = 5
      AGE_BUCKETS = %w[24_and_younger 25_to_29 30_to_34 35_to_44 45_to_54 55_and_older].freeze

      # cache: where answers are kept (a NullStore reads live every time); guard: what each live attempt asks first;
      # sleeper: how a retry waits (specs record the waits instead); on_response: called with path:, status: and body:
      # after every live HTTP answer, for the smoke test (Taste::Smoke) to read shapes in memory.
      def initialize(api_key:, base_url: ENV.fetch("QLOO_BASE_URL", DEFAULT_BASE_URL), cache: Rails.cache,
                     guard: CallGuard.new, retry_interval: 0.5, sleeper: ->(seconds) { sleep(seconds) }, on_response: nil)
        @api_key = api_key
        @base_url = base_url.to_s.chomp("/")
        @cache = cache
        @guard = guard
        @retry_interval = retry_interval
        @sleeper = sleeper
        @on_response = on_response
      end

      # A 404 here is Qloo's "No results" (R87).
      def search(query:, types:, take: 5)
        params = { "query" => query, "types" => Array(types).map { |t| Provider.urn_for(t) }, "take" => take }
        Mapping.entities(get("/search", params))
      rescue NotFound
        []
      end

      # types: tag type URNs to keep to, each an exact match ("urn:tag:genre:brand"); none means every type.
      def find_tags(query:, take: 10, types: [])
        Mapping.tags(get("/v2/tags", { "filter.query" => query, "feature.semantic_search" => true, "take" => take,
                               "filter.tag.types" => types }))
      end

      # offset (results to skip) or page (1 to 100) pages through a long list, as the catalog seed does; Qloo may
      # ignore page for brands and podcasts, so prefer offset.
      def recommend(type:, entity_ids: [], tag_ids: [], filter_tags: [], popularity_max: nil, take: 20, offset: nil,
                    page: nil)
        params = { "filter.type" => Provider.urn_for(type), "filter.tags" => filter_tags,
                   "filter.popularity.max" => popularity_max, "take" => take, "offset" => offset,
                   "page" => page }.merge(signals(entity_ids, tag_ids))
        Mapping.entities(get("/v2/insights", params))
      end

      # Qloo has no batch-affinity endpoint: scope insights to the candidates with filter.results.entities,
      # in chunks of 50. Every candidate id is a key; nil means Qloo returned no score for it.
      def affinity_for(candidate_ids:, entity_ids: [], tag_ids: [], type: :brand)
        ids = Array(candidate_ids).map(&:to_s)
        result = ids.to_h { |id| [ id, nil ] }
        ids.each_slice(AFFINITY_CHUNK) do |chunk|
          params = { "filter.type" => Provider.urn_for(type), "filter.results.entities" => chunk,
                     "take" => chunk.size }.merge(signals(entity_ids, tag_ids))
          Mapping.entities(get("/v2/insights", params)).each { |e| result[e.id] = e.affinity if chunk.include?(e.id) }
        end
        result
      end

      def taste_tags(entity_ids: [], tag_ids: [], take: 20)
        Mapping.tags(get("/v2/insights", { "filter.type" => "urn:tag", "take" => take }.merge(signals(entity_ids, tag_ids))))
      end

      # Qloo answers one block per signal (each seed entity and tag): every bucket is the mean over the blocks that
      # have it (R87).
      def demographics(entity_ids: [], tag_ids: [])
        Mapping.demographics(get("/v2/insights", { "filter.type" => "urn:demographics" }.merge(signals(entity_ids, tag_ids))))
      end

      # The documented geohash output (R106: the locality boundary param 502s). Qloo sends every cell whatever take
      # says, so only the HEATMAP_KEEP points with the most affinity are kept, and cached, never the whole answer. A
      # location Qloo can't place is a 400 (or a 404): it yields no points, so the caller's metro fallback runs (R87).
      def heatmap(location:, entity_ids: [], tag_ids: [], take: 50)
        params = { "filter.type" => "urn:heatmap", "filter.location.query" => location, "take" => take }
                   .merge(signals(entity_ids, tag_ids))
        Mapping.heat_points(get("/v2/insights", params, keep: ->(json) { Mapping.top_heatmap(json, HEATMAP_KEEP) }))
      rescue BadRequest, NotFound
        []
      end

      # A 404 here is Qloo's "No results" (R87).
      def compare(a_entity_ids:, b_entity_ids:, take: 10)
        params = { "a.signal.interests.entities" => a_entity_ids, "b.signal.interests.entities" => b_entity_ids, "take" => take }
        Mapping.tags(get("/v2/analysis/compare", params))
      rescue NotFound
        []
      end

      private

      def signals(entity_ids, tag_ids)
        out = { "signal.interests.entities" => entity_ids, "signal.interests.tags" => tag_ids }
        out["operator.signal.interests.tags"] = "union" if Array(tag_ids).size > 1
        out
      end

      # ---- HTTP ----

      # keep: trims a live answer before it is cached and returned. A remembered miss raises as the live one did.
      def get(path, params, keep: nil)
        params = normalize(params)
        key = cache_key(path, params)
        started = monotonic
        if (cached = @cache.read(key))
          miss = cached[MISS_KEY]
          notify(path, true, miss || 200, started)
          raise MISSES.fetch(miss), "Qloo #{path} returned HTTP #{miss} (remembered for a day)" if miss

          return cached
        end

        json = parse(path, live_body_remembering_misses(path, params, key))
        json = keep.call(json) if keep
        @cache.write(key, json, expires_in: STABLE_PATHS.include?(path) ? STABLE_CACHE_TTL : CACHE_TTL)
        json
      end

      def live_body_remembering_misses(path, params, key)
        live_body(path, params)
      rescue BadRequest, NotFound => e
        @cache.write(key, { MISS_KEY => MISSES.key(e.class) }, expires_in: MISS_TTL)
        raise
      end

      # The body of a 2xx answer, after at most one retry. Raises for any other outcome.
      def live_body(path, params)
        (1..ATTEMPTS).each do |attempt|
          retry_left = attempt < ATTEMPTS
          response = request_once(path, params, retry_left)
          next unless response # a timeout or a failed connection, waited out for the retry

          wait = retry_wait(response) if retry_left
          next @sleeper.call(wait) if wait

          raise_for_status!(path, params, response)
          return response.body
        end
      end

      # One HTTP request, after the call guard gives it a slot. nil when it failed in a way the retry may fix.
      def request_once(path, params, retry_left)
        @guard.acquire!
        started = monotonic
        response = connection.get(path, params)
        notify(path, false, response.status, started)
        @on_response&.call(path: path, status: response.status, body: response.body)
        response
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
        notify(path, false, nil, started)
        unavailable!(path, "failed: #{e.class}") unless retry_left
        @sleeper.call(@retry_interval)
        nil
      rescue Faraday::Error => e
        notify(path, false, nil, started)
        unavailable!(path, "failed: #{e.class}: #{e.message}")
      end

      # Seconds to wait before retrying this response, or nil when it isn't retried.
      def retry_wait(response)
        case response.status
        when 429 then retry_after(response)
        when 500..599 then @retry_interval
        end
      end

      # A 429's Retry-After (seconds or an HTTP date) when it is MAX_RETRY_AFTER seconds or less; nil otherwise.
      def retry_after(response)
        value = response.headers["Retry-After"].to_s.strip
        seconds = if value.match?(/\A\d+\z/) then value.to_i
        elsif value.present? then [ (Time.httpdate(value) - Time.current).ceil, 0 ].max
        end
        seconds if seconds && seconds <= MAX_RETRY_AFTER
      rescue ArgumentError
        nil
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

      # Only 401 means a bad key: Qloo's 403 means the key can't use that entity type (R87).
      def raise_for_status!(path, params, response)
        case response.status
        when 200..299 then nil
        when 400 then fail_with(BadRequest, path, params, response)
        when 401 then fail_with(AuthError, path, params, response)
        when 403 then fail_with(Unsupported, path, params, response)
        when 404 then fail_with(NotFound, path, params, response)
        when 429 then fail_with(RateLimited, path, params, response)
        when 500..599 then fail_with(Unavailable, path, params, response)
        else fail_with(Error, path, params, response)
        end
      end

      # Logs and raises with the param names only: never their values, and never the key (it lives in a header).
      def fail_with(klass, path, params, response)
        detail = begin
          body = JSON.parse(response.body.to_s)
          body["message"] if body.is_a?(Hash)
        rescue JSON::ParserError, TypeError
          nil
        end
        message = "Qloo #{path} returned HTTP #{response.status} (params: #{params.keys.sort.join(', ')})#{": #{detail}" if detail}"
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

      # No retry middleware: retries happen in live_body, so each one passes the call guard.
      def connection
        @connection ||= Faraday.new(url: @base_url, headers: { "X-Api-Key" => @api_key, "Accept" => "application/json" }) do |f|
          f.options.timeout = TIMEOUT
          f.options.open_timeout = OPEN_TIMEOUT
          f.adapter Faraday.default_adapter
        end
      end
    end
  end
end
