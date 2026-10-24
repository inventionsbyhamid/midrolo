module Research
  # Maps a show's directory categories to the brand categories worth searching for sponsors
  # (config/category_map.yml). Used by the scripted runner; the agent picks its own categories.
  module CategoryMap
    MAX = SponsorCandidates::MAX_CATEGORIES

    module_function

    # The first MAX distinct brand categories across the show's categories, in order; default when none map.
    def for(show_categories)
      mapped = Array(show_categories).flat_map { |c| table[Names.normalize(c)] || [] }
      (mapped.presence || defaults).uniq.first(MAX)
    end

    def table
      config.fetch(:categories, {}).to_h { |name, brands| [ Names.normalize(name), Array(brands).map(&:to_s) ] }
    end

    def defaults = Array(config[:default]).map(&:to_s)

    def config = Rails.application.config_for(:category_map)
  end
end
