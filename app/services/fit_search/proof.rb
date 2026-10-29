class FitSearch
  # Where brands like the searching one already sponsor: for each (brand, relation) pair, the shows its sponsor
  # history (Sponsors::History.for_brand, lane L2) names, as proof rows per podcast id:
  #   { podcast_id => [{ "brand", "slug", "relation", "episodes", "last_seen" }] }
  # Relations: you (the brand itself), competitor, complementary, category (FitSearch::Scoring::PROOF_WEIGHTS).
  module Proof
    module_function

    # links: [[Brand, relation]], each brand once (the first relation given wins).
    def call(links)
      rows = Hash.new { |hash, key| hash[key] = [] }
      links.uniq { |brand, _| brand.id }.each do |brand, relation|
        ::Sponsors::History.for_brand(brand).each do |history|
          podcast_id = podcast_id_of(history)
          next unless podcast_id

          rows[podcast_id] << { "brand" => brand.name, "slug" => brand.slug, "relation" => relation.to_s,
                                "episodes" => [ read(history, :episodes_count).to_i, 1 ].max,
                                "last_seen" => date_of(read(history, :last_seen)) }.compact
        end
      end
      rows.transform_values { |list| sort(list) }
    end

    # Strongest proof first: the relation's weight, then episodes.
    def sort(list)
      list.sort_by { |row| [ -Scoring::PROOF_WEIGHTS.fetch(row["relation"], 0), -row["episodes"].to_i, row["brand"].to_s ] }
    end

    # Sponsors::History rows may be objects or hashes; either way they name the podcast or its id.
    def podcast_id_of(history)
      id = read(history, :podcast_id)
      id ||= read(history, :podcast).then { |podcast| podcast.respond_to?(:id) ? podcast.id : podcast }
      Integer(id, exception: false) if id
    end

    def read(history, key)
      if history.is_a?(Hash) then history.fetch(key) { history[key.to_s] }
      elsif history.respond_to?(key) then history.public_send(key)
      end
    end

    def date_of(value)
      value = value.to_date if value.respond_to?(:to_date)
      value.is_a?(Date) ? value.iso8601 : nil
    rescue ArgumentError, TypeError
      nil
    end
  end
end
