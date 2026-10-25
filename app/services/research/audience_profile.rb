module Research
  # Builds the audience profile for a seed set and saves three report sections as it goes:
  #   audience     {brands: top 20, podcasts: top 10, tags: top 15}: a list per TYPES entry (config/research.yml,
  #                R93: brands and podcasts by default; artists and tv_shows, top 10 each, when configured)
  #   leans        {age: {bucket => lean}, gender: {gender => lean}} (the demographics column)
  #   map          {location: country code or "metros", country:, points: [{lat, lng, affinity, label}]} (heatmap),
  #                each label the nearest metro's name (Research::Places, R106) or nil
  # Returns {digest: String (< 1,500 chars, for the agent), thin: Boolean (fewer than 8 brands)}.
  #
  # A snapshot (R36) passes entities: false and include_demographics: false: the audience section then holds
  # only the taste tags, no leans are read or saved, and nothing but tags and the heatmap is asked of Qloo.
  #
  # The brand recommendation is essential and its errors propagate. Every other call is optional: on a Qloo
  # outage or rate limit it is skipped with a step warning and its part of the section is left empty.
  class AudienceProfile
    TAKE = { brand: 20, artist: 10, tv_show: 10, podcast: 10 }.freeze
    SECTION_KEYS = { brand: "brands", artist: "artists", tv_show: "tv_shows", podcast: "podcasts" }.freeze
    LABELS = { artist: "Artists", tv_show: "TV shows", podcast: "Podcasts" }.freeze
    NOUNS = { brand: "brands", artist: "artists", tv_show: "TV shows", podcast: "podcasts" }.freeze
    # config/research.yml (R93): the entity lists to fetch, brands first and always; and the metros to try.
    TYPES = ([ :brand ] + Array(Research.caps.fetch(:audience_entity_types)).map(&:to_sym)).uniq.freeze
    FALLBACK_METROS = Research.caps.fetch(:metro_fallback)
    TAG_TAKE = 15
    THIN_BELOW = 8
    HEATMAP_TAKE = 50
    MAX_POINTS = 200
    DIGEST_LIMIT = 1500

    def self.build(toolkit, seed_entity_ids:, seed_tag_ids:, country:, include_demographics: true, entities: true)
      new(toolkit, seed_entity_ids, seed_tag_ids, country, include_demographics: include_demographics, entities: entities).build
    end

    def initialize(toolkit, seed_entity_ids, seed_tag_ids, country, include_demographics: true, entities: true)
      @toolkit = toolkit
      @entity_ids = Array(seed_entity_ids).map(&:to_s).uniq
      @tag_ids = Array(seed_tag_ids).map(&:to_s).uniq
      @country = country.to_s.upcase
      @include_demographics = include_demographics
      @entities = entities
    end

    def build
      return { digest: "No seeds given. Find seeds on Qloo first.", thin: true } if @entity_ids.empty? && @tag_ids.empty?

      build_audience
      build_leans if @include_demographics
      build_map
      { digest: digest, thin: thin? }
    end

    private

    attr_reader :toolkit

    delegate :taste, :log, :report, to: :toolkit, private: true

    def signals = { entity_ids: @entity_ids, tag_ids: @tag_ids }

    def build_audience
      log.step("taste_profile", "Building your audience's taste profile…", input: seeds_input) do |step|
        @lists = @entities ? recommend_entities(step) : TYPES.index_with { [] }
        @tags = step.optional("Taste tags") { taste.taste_tags(**signals, take: TAG_TAKE) } || []

        toolkit.remember(@lists.values.flatten)
        toolkit.audience_tags = @tags
        report.save_section!(:audience, audience_section)
        step.warn!(@entities ? "Thin profile: only #{@lists[:brand].size} brands came back" : "No taste tags came back") if thin?
        step.output_summary = audience_summary
      end
    end

    def recommend_entities(step)
      lists = { brand: recommend(:brand) }
      (TYPES - [ :brand ]).each { |type| lists[type] = step.optional(LABELS.fetch(type)) { recommend(type) } || [] }
      lists
    end

    # "20 brands, 10 podcasts and 15 taste tags"
    def audience_summary
      return "#{@tags.size} taste tags" unless @entities

      counts = TYPES.map { |type| "#{@lists[type].size} #{NOUNS.fetch(type)}" } << "#{@tags.size} taste tags"
      Copy.and_list(counts)
    end

    # Seeds are inputs, not results: never list the show (or another seed) as something its audience loves.
    def recommend(type)
      taste.recommend(type: type, **signals, take: TAKE.fetch(type)).reject { |e| @entity_ids.include?(e.id) }
    end

    def build_leans
      log.step("demographics", "Reading your audience's age and gender leans…") do |step|
        @leans = step.optional("Age and gender leans") { taste.demographics(**signals) }
        report.save_section!(:leans, { "age" => (@leans&.age || {}).to_h, "gender" => (@leans&.gender || {}).to_h })
        step.output_summary = "Leans: #{leans_line}" if @leans
      end
    end

    def build_map
      log.step("heatmap", "Mapping where your listeners live…", input: country_name) do |step|
        @location = @country
        points = heatmap(step, country_name)
        if points.empty?
          metros = Array(Rails.application.config_for(:geo)[@country.to_sym]).first(FALLBACK_METROS)
          points = metros.flat_map { |metro| heatmap(step, metro) }
          @location = "metros" if points.any?
        end
        @points = points.sort_by { |p| -p.affinity.to_f }.first(MAX_POINTS)
        report.save_section!(:map, { "location" => @location, "country" => @country, "points" => @points.map { |p| point_json(p) } })
        step.output_summary = map_summary
      end
    end

    # Each point named after its nearest metro (R106: Qloo's geohash cells have no names), the report country's first,
    # so Top places can add up.
    def heatmap(step, location)
      points = step.optional(location) { taste.heatmap(location: location, **signals, take: HEATMAP_TAKE) } || []
      points.map { |point| point.with(label: Places.name_for(point.lat, point.lng, country: @country)) }
    end

    def thin? = @entities ? @lists[:brand].size < THIN_BELOW : @tags.empty?

    def country_name = Show::COUNTRIES.fetch(@country, @country)

    def seeds_input = "#{@entity_ids.size} entity and #{@tag_ids.size} tag seeds"

    # ---- section JSON ----

    def audience_section
      tags = { "tags" => @tags.map { |t| { "id" => t.id, "name" => t.name, "score" => t.score } } }
      return tags unless @entities

      TYPES.to_h { |type| [ SECTION_KEYS.fetch(type), @lists[type].map { |e| entity_json(e) } ] }.merge(tags)
    end

    def entity_json(entity)
      { "id" => entity.id, "name" => entity.name, "image_url" => entity.image_url, "affinity" => entity.affinity,
        "popularity" => entity.popularity, "website" => entity.website }
    end

    def point_json(point)
      { "lat" => point.lat, "lng" => point.lng, "affinity" => point.affinity, "label" => point.label }
    end

    # ---- digest for the agent: names, plus ids for brands ----

    def digest
      brands = @lists[:brand]
      lines = [ "Audience profile from #{seeds_input}." ]
      lines << "No brands came back for these seeds. Try different seeds." if brands.empty?
      lines << "Thin profile: only #{brands.size} brands came back. Consider different or more seeds." if thin? && brands.any?
      lines << "Brands: #{brands.first(12).map { |e| "#{e.name} (#{e.id})" }.join(', ')}" if brands.any?
      lines << names_line("Podcasts", @lists[:podcast], 8)
      lines << names_line("Taste tags", @tags, 10)
      lines << names_line("Artists", @lists[:artist], 5)
      lines << names_line("TV shows", @lists[:tv_show], 5)
      lines << "Leans (modeled from Qloo taste data): #{leans_line}" if @leans
      lines << "Map: #{map_summary}"
      lines.compact.join("\n").truncate(DIGEST_LIMIT - 1)
    end

    def names_line(label, items, count)
      items = Array(items)
      "#{label}: #{items.first(count).map(&:name).join(', ')}" if items.any?
    end

    # "age 25 to 29 and 30 to 34; female": the strongest positive leans, never percentages.
    def leans_line
      ages = top_leans(@leans.age, 2).map { |bucket| bucket.to_s.tr("_", " ") }
      gender = top_leans(@leans.gender, 1)
      parts = [ ages.any? ? "age #{ages.join(' and ')}" : nil, gender.any? ? gender.first.to_s : nil ].compact
      parts.any? ? parts.join("; ") : "no clear leans"
    end

    def top_leans(hash, count)
      hash.to_h.select { |_, v| v.to_f.positive? }.sort_by { |_, v| -v.to_f }.first(count).map(&:first)
    end

    def map_summary
      return "no map data for #{country_name}" if @points.blank?

      top = @points.filter_map(&:label).uniq.first(3)
      where = @location == "metros" ? "#{country_name} metros" : country_name
      "#{@points.size} areas across #{where}#{", strongest in #{Copy.and_list(top)}" if top.any?}"
    end
  end
end
