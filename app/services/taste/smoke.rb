module Taste
  # rake qloo:smoke (R92): the live smoke checklist (docs/live-smoke.md) against the real Qloo API, through
  # Taste::Providers::Qloo, within a hard budget of BUDGET live calls, retries included. Every attempt asks the budget
  # first, then the global call guard, so the smoke counts toward the day's calls; a spent budget or a refusal from the
  # guard aborts the run before the next call. It reads past the response cache to see what Qloo sends now, and writes
  # nothing anywhere: per call it prints the endpoint, the HTTP status, the result count, which parsing paths matched
  # and PASS or FAIL against the expectation, plus at most NAMES_SHOWN names. Never a body, an id or the key.
  #
  # It runs only with QLOO_API_KEY set, in development or production. STEPS=heatmap,search_miss runs only those checks,
  # in checklist order, plus the podcast search the others need (R107), so a rerun spends only what it checks. Specs
  # drive it against WebMock.
  class Smoke
    BUDGET = 10
    NAMES_SHOWN = 3
    PODCAST_QUERY = "SmartLess".freeze
    MISS_QUERY = "zzqxv nonexistent show".freeze
    BRAND_TAG_TYPE = "urn:tag:genre:brand".freeze
    BUSINESS_TAG = "urn:tag:genre:media:business".freeze
    COMEDY_TAG = "urn:tag:genre:media:comedy".freeze
    AGE_BUCKETS = 6
    # No compare (R105): Qloo's compare finds no shared tags between a podcast and a brand, so reports don't call it.
    STEPS = %i[search_podcast search_miss brand_tags brand_recs union demographics heatmap taste_tags].freeze
    # The checks that use the podcast the first one finds.
    NEEDS_PODCAST = %i[brand_recs demographics heatmap taste_tags].freeze

    class Refused < StandardError; end
    class BudgetSpent < StandardError; end

    # outcomes: {step => :pass, :fail or :skip} for the steps that ran; calls: live calls made; aborted: whether the
    # budget or the call guard stopped the run.
    Result = Data.define(:outcomes, :calls, :aborted) do
      def aborted? = aborted
      def passed? = !aborted && outcomes.any? && outcomes.values.all?(:pass)
    end

    # The guard the smoke's client asks: its own budget, then the global call guard.
    class Budget
      attr_reader :used

      def initialize(guard, limit)
        @guard = guard
        @limit = limit
        @used = 0
      end

      def acquire!
        raise BudgetSpent, "the budget of #{@limit} live calls is spent" if @used >= @limit

        @guard.acquire!
        @used += 1
      end
    end

    def self.call(**) = new(**).call

    def initialize(api_key: ENV["QLOO_API_KEY"], env: Rails.env, io: $stdout, sleeper: ->(seconds) { sleep(seconds) },
                   steps: ENV["STEPS"])
      @api_key = api_key.to_s.strip
      @env = env
      @io = io
      @sleeper = sleeper
      @asked = steps.to_s.split(",").map(&:strip).reject(&:empty?).map(&:to_sym)
    end

    def call
      refuse_unless_allowed!
      @steps = planned_steps
      @budget = Budget.new(CallGuard.new, BUDGET)
      @qloo = Providers::Qloo.new(api_key: @api_key, cache: ActiveSupport::Cache::NullStore.new, guard: @budget,
                                  sleeper: @sleeper, on_response: ->(status:, body:, **) { @last = { status: status, body: body } })
      @outcomes = {}
      @io.puts "Qloo smoke: #{@steps.size} checks, a hard budget of #{BUDGET} live calls. Shapes and counts only."
      aborted = run_steps
      result = Result.new(outcomes: @outcomes, calls: @budget.used, aborted: aborted)
      @io.puts summary(result)
      result
    end

    private

    def refuse_unless_allowed!
      raise Refused, "Qloo smoke refused: set QLOO_API_KEY first." if @api_key.empty?
      return if @env.development? || @env.production?

      raise Refused, "Qloo smoke refused: it runs only in development or production, not #{@env}."
    end

    # Every check, or the ones asked for plus the podcast search they need, in checklist order.
    def planned_steps
      return STEPS if @asked.empty?

      unknown = @asked - STEPS
      if unknown.any?
        raise Refused, "Qloo smoke refused: no #{'step'.pluralize(unknown.size)} called #{unknown.join(', ')}. " \
                       "The steps are #{STEPS.join(', ')}."
      end

      wanted = @asked.intersect?(NEEDS_PODCAST) ? @asked | [ :search_podcast ] : @asked
      STEPS & wanted
    end

    def run_steps
      @steps.each.with_index(1) { |step, number| send(step, number) }
      false
    rescue BudgetSpent, CallCapReached => e
      @io.puts "ABORT: #{e.is_a?(BudgetSpent) ? e.message : "the call guard refused (#{e.message})"}"
      true
    end

    def summary(result)
      counts = %i[pass fail skip].to_h { |outcome| [ outcome, result.outcomes.values.count(outcome) ] }
      "Qloo smoke: #{counts[:pass]} passed, #{counts[:fail]} failed, #{counts[:skip]} skipped; " \
        "#{result.calls} live calls of #{BUDGET}#{'; aborted' if result.aborted?}."
    end

    # ---- the checklist (docs/live-smoke.md) ----

    def search_podcast(number)
      check(number, :search_podcast, "/search", "HTTP 200 and a podcast") do
        results = @qloo.search(query: PODCAST_QUERY, types: [ :podcast ], take: 5)
        @podcast = results.find { |entity| entity.type == :podcast }
        [ results, ok? && @podcast.present?, search_shape + entity_shape ]
      end
    end

    # Qloo search is fuzzy (R107): a nonsense query gets the nearest shows with a 200, so a miss means no result whose
    # name is close to it, the test every caller applies (Research::Names.close?). A 404 means no results (M1).
    def search_miss(number)
      check(number, :search_miss, "/search", "no result close to the nonsense query (200 or 404)") do
        results = @qloo.search(query: MISS_QUERY, types: [ :podcast ], take: 5)
        close = results.any? { |entity| Research::Names.close?(entity.name, MISS_QUERY) }
        [ results, !close && [ 200, 404 ].include?(status), [] ]
      end
    end

    def brand_tags(number)
      check(number, :brand_tags, "/v2/tags", "HTTP 200 and brand tags only") do
        tags = @qloo.find_tags(query: "food and beverage", types: [ BRAND_TAG_TYPE ], take: 5)
        brand_only = tags.all? { |tag| tag.id.start_with?("#{BRAND_TAG_TYPE}:") }
        food = tags.any? { |tag| tag.id == "#{BRAND_TAG_TYPE}:food_and_beverage" }
        [ tags, ok? && tags.any? && brand_only, tag_shape + [ "food_and_beverage #{food ? 'present' : 'absent'}" ] ]
      end
    end

    def brand_recs(number)
      return skip(number, :brand_recs, "/v2/insights", "no podcast was found") unless @podcast

      check(number, :brand_recs, "/v2/insights", "HTTP 200 and brands with an affinity from 0 to 1") do
        brands = @qloo.recommend(type: :brand, entity_ids: [ @podcast.id ], popularity_max: 0.97, take: 5)
        scored = brands.any? && brands.all? { |brand| brand.affinity&.between?(0, 1) }
        [ brands, ok? && scored, entity_shape ]
      end
    end

    def union(number)
      check(number, :union, "/v2/insights", "HTTP 200 and brands for two tags joined by union") do
        brands = @qloo.recommend(type: :brand, tag_ids: [ BUSINESS_TAG, COMEDY_TAG ], take: 10)
        [ brands, ok? && brands.any?, [] ]
      end
    end

    def demographics(number)
      return skip(number, :demographics, "/v2/insights", "no podcast was found") unless @podcast

      check(number, :demographics, "/v2/insights", "HTTP 200, one block per signal (2) and #{AGE_BUCKETS} age buckets") do
        @qloo.demographics(entity_ids: [ @podcast.id ], tag_ids: [ BUSINESS_TAG ])
        blocks = Array(results_in("demographics")).select { |block| block.is_a?(Hash) }
        ages = blocks.flat_map { |block| Array(block.dig("query", "age")&.keys) }.uniq.size
        genders = blocks.flat_map { |block| Array(block.dig("query", "gender")&.keys) }.uniq.size
        shape = [ "#{blocks.size} demographics #{'block'.pluralize(blocks.size)}", "#{ages} age buckets", "#{genders} genders" ]
        [ blocks, ok? && blocks.size == 2 && ages == AGE_BUCKETS, shape ]
      end
    end

    def heatmap(number)
      return skip(number, :heatmap, "/v2/insights", "no podcast was found") unless @podcast

      check(number, :heatmap, "/v2/insights", "HTTP 200 and points for the country") do
        points = @qloo.heatmap(location: "United States", entity_ids: [ @podcast.id ], take: 10)
        note = status == 400 ? [ "a 400: Qloo can't place the country, so reports use the metro fallback (M2)" ] : []
        [ points, ok? && points.any?, heatmap_shape + note ]
      end
    end

    def taste_tags(number)
      return skip(number, :taste_tags, "/v2/insights", "no podcast was found") unless @podcast

      check(number, :taste_tags, "/v2/insights", "HTTP 200 and tags with a score") do
        tags = @qloo.taste_tags(entity_ids: [ @podcast.id ], take: 10)
        [ tags, ok? && tags.any? { |tag| tag.score }, tag_shape ]
      end
    end


    # ---- running and printing one check ----

    # The block makes one call and returns [items, passed, parsing paths]. A Qloo error fails the check; a spent budget
    # or the call guard's refusal ends the run.
    def check(number, name, path, expectation)
      @last = nil
      items, passed, shape = begin
        yield
      rescue CallCapReached
        raise
      rescue Error => e
        [ [], false, [ "raised #{e.class.name}" ] ]
      end
      record(number, name, passed ? :pass : :fail, path: path, status: status, items: items, shape: shape, expectation: expectation)
    end

    def skip(number, name, path, reason)
      record(number, name, :skip, path: path, status: nil, items: [], shape: [], expectation: "skipped: #{reason}")
    end

    def record(number, name, outcome, path:, status:, items:, shape:, expectation:)
      @outcomes[name] = outcome
      count = "#{items.size} #{'result'.pluralize(items.size)}"
      @io.puts "#{number}. #{name}  GET #{path}  HTTP #{status || 'none'}  #{count}  #{outcome.to_s.upcase}"
      @io.puts "   expected: #{expectation}"
      @io.puts "   parsing: #{shape.join('; ')}" if shape.any?
      names = items.filter_map { |item| item.try(:name).presence || item.try(:label).presence }.first(NAMES_SHOWN)
      @io.puts "   names: #{names.join(', ')}" if names.any?
    end

    def status = @last&.dig(:status)

    def ok? = status.to_i.between?(200, 299)

    # The last answer's JSON, parsed in memory only.
    def json
      body = JSON.parse(@last&.dig(:body).to_s)
      body.is_a?(Hash) ? body : {}
    rescue JSON::ParserError
      {}
    end

    def results_in(key)
      results = json["results"]
      results.is_a?(Hash) ? results[key] : nil
    end

    # ---- parsing paths: which of the shapes the client reads came back (key names and counts only) ----

    def search_shape
      results = json["results"]
      [ results.is_a?(Array) ? "results as a flat list" : "results.entities" ]
    end

    def entity_shape
      results = json["results"]
      list = Array(results.is_a?(Hash) ? results["entities"] : results).select { |entity| entity.is_a?(Hash) }
      tally(list.flat_map do |entity|
        props = entity["properties"].is_a?(Hash) ? entity["properties"] : {}
        [ "type at #{entity['subtype'] ? 'subtype' : 'types'}", "image at #{image_path(props, entity)}",
          "description at #{first_path(props, entity, 'description')}",
          "website at #{website_path(props, entity)}", "affinity at #{affinity_path(entity)}",
          "tags at #{first_path(props, entity, 'tags')}" ]
      end)
    end

    def tag_shape
      results = json["results"]
      list = Array(results.is_a?(Hash) ? results["tags"] : results).select { |tag| tag.is_a?(Hash) }
      tally(list.flat_map do |tag|
        [ "id at #{tag['id'] ? 'id' : 'tag_id'}", "type at #{tag['subtype'] ? 'subtype' : 'type'}",
          "score at #{%w[score affinity].find { |key| tag.dig('query', key) }&.then { |key| "query.#{key}" } || 'none'}" ]
      end)
    end

    def heatmap_shape
      tally(Array(results_in("heatmap")).select { |point| point.is_a?(Hash) }.map do |point|
        location = point["location"].is_a?(Hash) ? point["location"] : nil
        keys = location ? location.keys.map { |key| "location.#{key}" } : point.keys
        lat = keys.find { |key| key.end_with?("latitude", "lat") } || "none"
        lng = keys.find { |key| key.end_with?("longitude", "lon", "lng") } || "none"
        "points at #{lat}/#{lng}"
      end)
    end

    def image_path(props, entity)
      if props["image"].is_a?(Hash) && props["image"]["url"] then "properties.image.url"
      elsif props["image"].is_a?(String) then "properties.image"
      elsif entity["image"].is_a?(Hash) && entity["image"]["url"] then "image.url (flat)"
      elsif entity["image"].is_a?(String) then "image (flat)"
      elsif entity["url"].is_a?(String) then "url (flat)"
      else "none"
      end
    end

    def website_path(props, entity)
      return "properties.official_site" if props["official_site"]
      return "official_site (flat)" if entity["official_site"]
      return "properties.websites" if Array(props["websites"]).any?

      Array(entity["websites"]).any? ? "websites (flat)" : "none"
    end

    def affinity_path(entity)
      return "query.affinity" if entity.dig("query", "affinity")

      entity["affinity"] ? "affinity (flat)" : "none"
    end

    def first_path(props, entity, key)
      return "properties.#{key}" if props[key].present?

      entity[key].present? ? "#{key} (flat)" : "none"
    end

    # "image at none (1); image at properties.image.url (2)" from a list of path labels, grouped by field.
    def tally(labels) = labels.tally.sort.map { |label, count| "#{label} (#{count})" }
  end
end
