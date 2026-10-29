class FitSearch
  # Brand categories for a fit search, and the podcast directory categories each one covers: config/category_map.yml
  # read the other way round (it maps a show's category to the brand categories that sponsor it). Each category is
  # also a Qloo brand tag (urn:tag:genre:brand:<key>), so a brand Qloo doesn't know by name can still signal by it.
  module Categories
    TAG_TYPE = "urn:tag:genre:brand".freeze
    TAG_PREFIX = "#{TAG_TYPE}:".freeze
    # Podcast categories looked in per search, from the brand's first categories.
    MAX_BRAND_CATEGORIES = 3

    module_function

    # Every brand category the map knows, in a stable order for the search form.
    def names
      Research::CategoryMap.table.values.flatten.concat(Research::CategoryMap.defaults).uniq.sort
    end

    # The names among the given ones that the map knows, written as the map writes them; unknown ones are dropped.
    def known(values)
      by_key = names.index_by { |name| key(name) }
      Array(values).filter_map { |value| by_key[key(value)] }.uniq
    end

    # The podcast categories (as feeds name them) that the brand categories cover.
    def podcast_categories_for(brand_categories)
      wanted = Array(brand_categories).map { |name| key(name) }.to_set
      config_categories.filter_map { |podcast_category, brands| podcast_category if brands.any? { |b| wanted.include?(key(b)) } }
    end

    # The Qloo brand tag for a category ("Food & Beverage" => "urn:tag:genre:brand:food_and_beverage").
    def tag_id_for(name) = "#{TAG_PREFIX}#{name.to_s.downcase.gsub('&', ' and ').parameterize(separator: '_')}"

    # The categories among a Qloo entity's tags: its urn:tag:genre:brand:<key> tags that the map knows.
    def from_tags(tags)
      Array(tags).filter_map do |tag|
        next unless tag.id.to_s.start_with?(TAG_PREFIX)

        known([ tag.name, tag.id.to_s.delete_prefix(TAG_PREFIX).split(":").first.to_s.tr("_", " ") ]).first
      end.uniq
    end

    def key(name) = Research::Names.normalize(name)

    def config_categories = Research::CategoryMap.config.fetch(:categories, {}).to_h { |name, brands| [ name.to_s, Array(brands).map(&:to_s) ] }
  end
end
