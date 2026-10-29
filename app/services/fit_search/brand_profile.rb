class FitSearch
  # What a fit search keeps about a brand from its Qloo entity (Brand::Workspace describes the shape): its tags, the
  # categories they map to, and the competitors, complementary brands and industries Qloo's brand data lists. Qloo's
  # docs don't pin down how those brand fields are shaped (a list of names, of entities, or one string), so each is
  # read tolerantly.
  module BrandProfile
    TAG_LIMIT = 30
    NAME_LIMIT = 10
    LIST_KEYS = { "competitors" => %w[competitive_set competitors], "complementary" => %w[complementary_brands complementary] }.freeze

    module_function

    def from_entity(entity, now: Time.current)
      props = entity.properties.is_a?(Hash) ? entity.properties : {}
      {
        "entity_id" => entity.id.to_s, "name" => entity.name.to_s, "fetched_at" => now.utc.iso8601,
        "tags" => Array(entity.tags).first(TAG_LIMIT).map { |tag| { "id" => tag.id.to_s, "name" => tag.name.to_s, "type" => tag.type.to_s } },
        "categories" => Categories.from_tags(entity.tags),
        "industries" => names_in(props["industries"]).pluck("name")
      }.merge(LIST_KEYS.to_h { |list, keys| [ list, names_in(props.values_at(*keys).compact.first).reject { |row| same_brand?(row, entity) } ] })
    end

    # The brand's own tags, as Taste::Tag values, from a stored profile.
    def tags(profile)
      Array(profile.is_a?(Hash) ? profile["tags"] : nil).filter_map do |row|
        Taste::Tag.new(id: row["id"].to_s, name: row["name"].to_s, type: row["type"].presence, score: nil) if row.is_a?(Hash) && row["id"].present?
      end
    end

    # [{ "name", "id" }] from a list of names, of hashes with a name, or a comma separated string.
    def names_in(value)
      list = case value
      when Array then value
      when Hash then value["entities"] || value["brands"] || value["results"] || []
      when String then value.split(/[,;]/)
      else []
      end
      Array(list).filter_map { |item| name_row(item) }.uniq { |row| Research::Names.normalize(row["name"]) }.first(NAME_LIMIT)
    end

    def name_row(item)
      name, id = item.is_a?(Hash) ? [ item["name"], item["entity_id"] || item["id"] ] : [ item, nil ]
      name = name.to_s.squish.first(Brand::NAME_LIMIT)
      return nil if name.blank? || Research::Names.normalize(name).blank?

      { "name" => name, "id" => id.presence&.to_s }.compact
    end

    def same_brand?(row, entity) = (row["id"].present? && row["id"] == entity.id.to_s) || Research::Names.same?(row["name"], entity.name)
  end
end
