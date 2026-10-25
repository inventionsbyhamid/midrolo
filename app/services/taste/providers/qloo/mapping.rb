module Taste
  module Providers
    class Qloo
      # Reads Qloo's JSON into Taste value objects. The docs are inconsistent, so every rule is tolerant and lives here
      # once: entities and tags in either list shape, fields flat or under properties, demographics averaged over
      # their per-signal blocks, heatmap points under any of the coordinate keys Qloo has used (R87).
      module Mapping
        module_function

        def demographics(json)
          queries = Array(dig_results(json, "demographics")).filter_map { |block| block["query"] if block.is_a?(Hash) && block["query"].is_a?(Hash) }
          Demographics.new(age: mean_leans(queries.map { |q| q["age"] }), gender: mean_leans(queries.map { |q| q["gender"] }))
        end

        # The heatmap answer cut to the keep entries with the most affinity (entries without one last), and nothing else.
        def top_heatmap(json, keep)
          entries = Array(dig_results(json, "heatmap")).select { |h| h.is_a?(Hash) }
          top = entries.sort_by { |h| -(float(heat_query(h)["affinity"] || h["affinity"]) || -1.0) }.first(keep)
          { "results" => { "heatmap" => top } }
        end

        # The points Qloo's heatmap answer holds; a non-empty answer that reads as no points is logged with its keys.
        def heat_points(json)
          raw = Array(dig_results(json, "heatmap")).select { |h| h.is_a?(Hash) }
          points = raw.filter_map { |h| heat_point(h) }
          warn_unparsed_heatmap(raw) if raw.any? && points.empty?
          points
        end

        def dig_results(json, key)
          results = json["results"]
          results.is_a?(Hash) ? results[key] : nil
        end

        def entities(json)
          results = json["results"]
          list = results.is_a?(Hash) ? results["entities"] : results
          Array(list).filter_map { |e| entity(e) if e.is_a?(Hash) }
        end

        # Image, description, website and tags may sit flat on the entity or under properties (R87).
        def entity(e)
          props = e["properties"].is_a?(Hash) ? e["properties"] : {}
          urn = e["subtype"] || Array(e["types"]).first
          Entity.new(
            id: (e["entity_id"] || e["id"]).to_s, name: e["name"].to_s, type: Provider.type_for(urn) || urn,
            popularity: float(e["popularity"]), affinity: float(e.dig("query", "affinity") || e["affinity"]),
            image_url: image_url(props, e), description: text(props["description"]) || text(e["description"]),
            website: text(props["official_site"]) || text(e["official_site"]) ||
                     text(Array(props["websites"]).first) || text(Array(e["websites"]).first),
            tags: (Array(e["tags"]).presence || Array(props["tags"])).filter_map { |t| tag(t) if t.is_a?(Hash) }, properties: props
          )
        end

        # properties.image.url, properties.image, image.url, image, then the flat url Qloo's taxonomy shows for brands.
        def image_url(props, e)
          [ props["image"], e["image"] ].each do |image|
            url = text(image.is_a?(Hash) ? image["url"] : image)
            return url if url
          end
          text(e["url"])
        end

        def text(value) = value.is_a?(String) && value.present? ? value : nil

        def tags(json)
          results = json["results"]
          list = results.is_a?(Hash) ? results["tags"] : results
          Array(list).filter_map { |t| tag(t) if t.is_a?(Hash) }
        end

        def tag(t)
          Tag.new(id: (t["id"] || t["tag_id"]).to_s, name: t["name"].to_s, type: t["type"] || t["subtype"],
                  score: float(t.dig("query", "score") || t.dig("query", "affinity") || t["score"]))
        end

        # Latitude as latitude or lat, longitude as longitude, lon or lng, under location or flat (R87).
        def heat_point(h)
          loc = h["location"].is_a?(Hash) ? h["location"] : {}
          query = heat_query(h)
          lat = float(loc["latitude"] || loc["lat"] || h["latitude"] || h["lat"])
          lng = float(loc["longitude"] || loc["lon"] || loc["lng"] || h["longitude"] || h["lon"] || h["lng"])
          return nil unless lat && lng && lat.abs <= 90 && lng.abs <= 180

          HeatPoint.new(lat: lat, lng: lng, geohash: loc["geohash"] || h["geohash"],
                        affinity: float(query["affinity"] || h["affinity"]), popularity: float(query["popularity"] || h["popularity"]),
                        label: text(loc["name"] || h["name"] || loc["city"] || loc["locality"]))
        end

        # A heatmap entry's query block; {} when it is missing or isn't a hash (Task 20: no TypeError after a spent call).
        def heat_query(h) = h["query"].is_a?(Hash) ? h["query"] : {}

        # A shape we don't read would empty the map silently: say which keys came back instead.
        def warn_unparsed_heatmap(raw)
          keys = raw.flat_map do |h|
            h.flat_map { |key, value| value.is_a?(Hash) ? value.keys.map { |inner| "#{key}.#{inner}" } : [ key ] }
          end
          Rails.logger.warn("[Qloo] /v2/insights: #{raw.size} heatmap entries parsed to no points; keys seen: #{keys.uniq.sort.join(', ')}")
        end

        def leans(hash)
          (hash.is_a?(Hash) ? hash : {}).transform_values { |v| float(v) }
        end

        # Each bucket's mean over the hashes that have a number for it, to 3 places.
        def mean_leans(hashes)
          rows = hashes.map { |h| leans(h).compact }.reject(&:empty?)
          rows.flat_map(&:keys).uniq.to_h do |key|
            values = rows.filter_map { |row| row[key] }
            [ key, (values.sum / values.size).round(3) ]
          end
        end

        def float(value)
          value.nil? ? nil : Float(value)
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
