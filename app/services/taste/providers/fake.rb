module Taste
  module Providers
    # Offline adapter backed by config/fake_taste_catalog.yml. Selected automatically when QLOO_API_KEY is missing
    # outside production. Deterministic: randomness is seeded from a digest of the sorted inputs.
    class Fake
      CATALOG_PATH = Rails.root.join("config/fake_taste_catalog.yml")
      AGE_BUCKETS = %w[24_and_younger 25_to_29 30_to_34 35_to_44 45_to_54 55_and_older].freeze
      GENDERS = %w[male female].freeze
      BRAND_TAG_TYPE = "urn:tag:genre:brand".freeze
      MEDIA_TAG_TYPE = "urn:tag:genre:media".freeze
      GEOHASH_BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz".freeze

      def initialize
        @catalog = YAML.load_file(CATALOG_PATH)
        @tags = build_tags
        @entities = build_entities
      end

      def search(query:, types:, take: 5)
        instrument("search") do
          wanted = Array(types).map { |t| Provider.urn_for(t) && t.to_sym }
          q = query.to_s.strip.downcase
          scored = @entities.values.filter_map do |e|
            next unless wanted.include?(e.type)

            rank = match_rank(e.name.downcase, q)
            [ rank, -e.popularity, e.name, e ] if rank
          end
          scored.sort_by { |row| row[0..2] }.first(take).map(&:last)
        end
      end

      def find_tags(query:, take: 10, types: [])
        instrument("find_tags") do
          q = query.to_s.strip.downcase
          wanted = Array(types).map(&:to_s)
          scored = @tags.values.filter_map do |t|
            next if wanted.any? && !wanted.include?(t.type)

            rank = match_rank(t.name.downcase, q) || match_rank(t.id.split(":").last.tr("_", " "), q)
            [ rank, t.name, t ] if rank
          end
          scored.sort_by { |row| row[0..1] }.first(take).map(&:last)
        end
      end

      def recommend(type:, entity_ids: [], tag_ids: [], filter_tags: [], popularity_max: nil, take: 20)
        instrument("recommend") do
          Provider.urn_for(type)
          rng = rng_for("recommend", type, entity_ids, tag_ids, filter_tags, popularity_max)
          pool = @entities.values.select { |e| e.type == type.to_sym && !Array(entity_ids).include?(e.id) }
          pool = pool.select { |e| (Array(filter_tags) - e.tags.map(&:id)).empty? } if Array(filter_tags).any?
          pool = pool.select { |e| e.popularity <= popularity_max } if popularity_max
          pool.sort_by(&:id).map { |e| e.with(affinity: (0.3 + rng.rand * 0.7).round(3)) }
              .sort_by { |e| [ -e.affinity, e.id ] }.first(take)
        end
      end

      def affinity_for(candidate_ids:, entity_ids: [], tag_ids: [], type: :brand)
        instrument("affinity_for") do
          Provider.urn_for(type)
          Array(candidate_ids).to_h do |id|
            known = @entities[id]
            score = known && known.type != type.to_sym ? nil : 0.2 + rng_for("affinity", id, entity_ids, tag_ids).rand * 0.75
            [ id, score&.round(3) ]
          end
        end
      end

      def taste_tags(entity_ids: [], tag_ids: [], take: 20)
        instrument("taste_tags") do
          rng = rng_for("taste_tags", entity_ids, tag_ids)
          scored = @tags.values.sort_by(&:id).map { |t| t.with(score: (0.2 + rng.rand * 0.8).round(3)) }
          scored.sort_by { |t| [ -t.score, t.id ] }.first(take)
        end
      end

      def demographics(entity_ids: [], tag_ids: [])
        instrument("demographics") do
          rng = rng_for("demographics", entity_ids, tag_ids)
          Demographics.new(age: AGE_BUCKETS.to_h { |b| [ b, lean(rng) ] }, gender: GENDERS.to_h { |g| [ g, lean(rng) ] })
        end
      end

      def heatmap(location:, entity_ids: [], tag_ids: [], take: 50)
        instrument("heatmap") do
          centers = centers_for(location)
          next [] if centers.empty?

          rng = rng_for("heatmap", location.to_s.downcase, entity_ids, tag_ids)
          count = [ rng.rand(20..50), take ].min
          Array.new(count) do
            _name, lat0, lng0 = centers[rng.rand(centers.size)]
            lat = (lat0 + (rng.rand - 0.5) * 0.4).round(4)
            lng = (lng0 + (rng.rand - 0.5) * 0.4).round(4)
            HeatPoint.new(lat: lat, lng: lng, geohash: geohash(lat, lng), affinity: (0.2 + rng.rand * 0.8).round(3),
                          popularity: (rng.rand * 0.6).round(3), label: nearest_metro(lat, lng))
          end
        end
      end

      def compare(a_entity_ids:, b_entity_ids:, take: 10)
        instrument("compare") do
          rng = rng_for("compare", a_entity_ids, b_entity_ids)
          n = [ rng.rand(5..10), take ].min
          pool = @tags.values.sort_by(&:id)
          picked = pool.shuffle(random: rng).first(n).map { |t| t.with(score: (0.3 + rng.rand * 0.7).round(3)) }
          picked.sort_by { |t| [ -t.score, t.id ] }
        end
      end

      private

      def instrument(method)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        ActiveSupport::Notifications.instrument("request.taste", path: "fake:#{method}", cached: false, status: 200,
          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1))
        result
      end

      def rng_for(*inputs)
        parts = inputs.map { |i| i.is_a?(Array) ? i.map(&:to_s).sort.join(",") : i.to_s }
        Random.new(Digest::SHA256.hexdigest(parts.join("|"))[0, 15].to_i(16))
      end

      def lean(rng) = ((rng.rand * 2 - 1) * 0.6).round(2)

      def match_rank(name, q)
        return nil if q.empty?
        return 0 if name == q
        return 1 if name.start_with?(q)
        return 2 if name.include?(q)

        3 if q.split.any? { |tok| tok.length > 2 && name.include?(tok) }
      end

      # ---- catalog ----

      def build_tags
        tags = {}
        @catalog["media_genres"].each { |k, name| tags["urn:tag:genre:media:#{k}"] = Tag.new(id: "urn:tag:genre:media:#{k}", name: name, type: MEDIA_TAG_TYPE, score: nil) }
        @catalog["brands"].each_key do |cat|
          id = "#{BRAND_TAG_TYPE}:#{cat}"
          tags[id] = Tag.new(id: id, name: category_name(cat), type: BRAND_TAG_TYPE, score: nil)
        end
        @catalog["extra_tags"].each { |t| tags[t["id"]] = Tag.new(id: t["id"], name: t["name"], type: t["type"], score: nil) }
        tags
      end

      def build_entities
        out = {}
        add = lambda do |type, name, popularity, tag, website: nil, description: nil|
          id = "fake:#{type}:#{slug(name)}"
          out[id] = Entity.new(id: id, name: name, type: type, popularity: popularity.to_f, affinity: nil, image_url: nil,
                               description: description, website: website, tags: [ tag ].compact, properties: {})
        end
        @catalog["brands"].each do |cat, brands|
          tag = @tags["#{BRAND_TAG_TYPE}:#{cat}"]
          brands.each { |name, pop| add.call(:brand, name, pop, tag, website: "https://#{slug(name)}.example.com", description: "Sample #{tag.name.downcase} brand.") }
        end
        { artist: "artists", tv_show: "tv_shows" }.each do |type, key|
          @catalog[key].each { |name, pop| add.call(type, name, pop, nil, description: "Sample #{type.to_s.tr('_', ' ')}.") }
        end
        @catalog["podcasts"].each do |name, attrs|
          add.call(:podcast, name, attrs["popularity"], @tags["urn:tag:genre:media:#{attrs['genre']}"], description: "Sample podcast.")
        end
        out
      end

      def slug(name) = name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")

      # "food_and_beverage" => "Food and Beverage", as Qloo names its brand categories.
      def category_name(key) = key.split("_").map { |word| word == "and" ? word : word.capitalize }.join(" ")

      # ---- geo ----

      def metros = @catalog["metros"]

      def centers_for(location)
        loc = location.to_s.strip.downcase
        return [] if loc.empty?

        code, country = @catalog["countries"].find { |c, v| c.downcase == loc || v["name"].downcase == loc }
        if code
          list = metros.filter_map { |name, (cc, lat, lng)| [ name, lat, lng ] if cc == code }
          return list.empty? ? [ [ country["name"], country["lat"], country["lng"] ] ] : list
        end
        metro = metros.find { |name, _| name.downcase == loc }
        metro ? [ [ metro[0], metro[1][1], metro[1][2] ] ] : []
      end

      def nearest_metro(lat, lng)
        metros.min_by { |_, (_, mlat, mlng)| (mlat - lat)**2 + (mlng - lng)**2 }.first
      end

      def geohash(lat, lng, precision = 7)
        lat_r = [ -90.0, 90.0 ]
        lng_r = [ -180.0, 180.0 ]
        bits = []
        even = true
        while bits.size < precision * 5
          range, value = even ? [ lng_r, lng ] : [ lat_r, lat ]
          mid = (range[0] + range[1]) / 2
          if value >= mid
            bits << 1
            range[0] = mid
          else
            bits << 0
            range[1] = mid
          end
          even = !even
        end
        bits.each_slice(5).map { |b| GEOHASH_BASE32[b.join.to_i(2)] }.join
      end
    end
  end
end
