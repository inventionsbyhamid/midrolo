module Matching
  # A report's shows with a similar audience (reports.similar_podcasts, saved by Research::SimilarPodcasts) with what the
  # catalog knows about them: each one's podcast, and the brands their own feeds show sponsoring them (sponsor_mentions).
  # #sponsors is "Brands that already sponsor shows like yours" (build spec L8), and #proof_for puts a brand's share of
  # it on its sponsor match. Three queries (and the artwork's preloads) whatever the list's length, run on first use;
  # none when the report has no similar shows in the catalog. A removed podcast counts as not in the catalog.
  class SimilarShows
    # One similar show: Qloo's name and score, its catalog podcast (nil when the catalog doesn't have it) and the brands
    # seen sponsoring it, the most recent first.
    Item = Data.define(:name, :score, :qloo_entity_id, :podcast, :brands)
    # A brand seen sponsoring similar shows: those podcasts (the most recent first), its sponsored episodes across them,
    # and when it was last seen.
    Sponsor = Data.define(:brand, :podcasts, :episodes, :last_seen)

    def self.for(report) = new(report)

    def initialize(report)
      @report = report
    end

    def items = loaded.fetch(:items)

    # Most similar shows sponsored first, then the most episodes, then the latest.
    def sponsors = loaded.fetch(:sponsors)

    def any? = items.any?

    # The brand of a SponsorMatch among #sponsors (by its Qloo entity, else its name), or nil.
    def proof_for(match)
      brand = brands_by_entity[match.brand_entity_id.to_s] || brands_by_name[Brand.name_key_for(match.name)]
      sponsors_by_brand[brand.id] if brand
    end

    private

    def loaded
      @loaded ||= load
    end

    def load
      entries = Array(@report.similar_podcasts).select { |entry| entry.is_a?(Hash) && entry["name"].present? }
      podcasts = catalog_podcasts(entries)
      rows = mention_rows(podcasts.keys)
      brands = rows.empty? ? {} : Brand.where(id: rows.map(&:first).uniq).index_by(&:id)
      rows = rows.select { |(brand_id, _)| brands.key?(brand_id) }
      { items: entries.map { |entry| item(entry, podcasts, rows, brands) }, sponsors: sponsor_list(rows, podcasts, brands) }
    end

    # {id => Podcast} for the entries in the catalog, without the report's own podcast or a removed one.
    def catalog_podcasts(entries)
      ids = entries.filter_map { |entry| Integer(entry["podcast_id"], exception: false) }.uniq
      ids -= [ @report.show.podcast_id ] if ids.any?
      return {} if ids.empty?

      Podcast.where(id: ids).where.not(status: "removed").includes(artwork_image: { file_attachment: :blob }).index_by(&:id)
    end

    # [[brand_id, podcast_id, episodes, last_seen]], one per brand and podcast.
    def mention_rows(podcast_ids)
      return [] if podcast_ids.empty?

      SponsorMention.where(podcast_id: podcast_ids).group(:brand_id, :podcast_id)
                    .pluck(:brand_id, :podcast_id, Arel.sql("COUNT(*)"), Arel.sql("MAX(sponsor_mentions.published_at)"))
    end

    def item(entry, podcasts, rows, brands)
      podcast = podcasts[Integer(entry["podcast_id"], exception: false)]
      sponsored = podcast ? rows.select { |row| row[1] == podcast.id }.sort_by { |row| [ -seen(row[3]), row[0] ] } : []
      Item.new(name: entry["name"].to_s, score: entry["score"], qloo_entity_id: entry["qloo_entity_id"].to_s,
               podcast: podcast, brands: sponsored.map { |row| brands.fetch(row[0]) })
    end

    def sponsor_list(rows, podcasts, brands)
      rows.group_by(&:first).map do |brand_id, brand_rows|
        latest_first = brand_rows.sort_by { |row| -seen(row[3]) }
        Sponsor.new(brand: brands.fetch(brand_id), podcasts: latest_first.map { |row| podcasts.fetch(row[1]) },
                    episodes: brand_rows.sum { |row| row[2] }, last_seen: latest_first.first[3])
      end.sort_by { |s| [ -s.podcasts.size, -s.episodes, -seen(s.last_seen), s.brand.name.downcase ] }
    end

    def seen(time) = time.to_f

    def sponsors_by_brand = @sponsors_by_brand ||= sponsors.index_by { |sponsor| sponsor.brand.id }

    def brands_by_entity
      @brands_by_entity ||= sponsors.filter_map { |s| [ s.brand.qloo_entity_id, s.brand ] if s.brand.qloo_entity_id.present? }.to_h
    end

    # The first (most proven) brand for each name key.
    def brands_by_name
      @brands_by_name ||= sponsors.each_with_object({}) { |s, index| index[s.brand.name_key] ||= s.brand }
    end
  end
end
