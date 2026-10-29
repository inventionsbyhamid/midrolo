module Sponsors
  # Sponsor history from sponsor_mentions, one aggregate query each, the most recent first:
  #
  #   Sponsors::History.for(podcast)        the brands that sponsored the podcast (rows with brand set)
  #   Sponsors::History.for_brand(brand)    the podcasts the brand sponsored (rows with podcast set); podcasts:
  #                                         narrows them (Podcast.listed on the brand page)
  #   Sponsors::History.for_brands(brands)  the same for several brands at once, one row per brand and podcast
  #
  # Each Row: brand and podcast (records; the side that was asked about is the record passed in), brand_id, podcast_id,
  # episodes_count, first_seen and last_seen (the episodes' published_at), promo_codes (newest first, at most
  # CODES), offer and url (the newest given), evidence with the episode it came from (evidence_episode_slug and
  # evidence_episode_title), and confidence (the highest). Removed podcasts never appear.
  module History
    CODES = 3

    Row = Data.define(:brand, :podcast, :brand_id, :podcast_id, :episodes_count, :first_seen, :last_seen, :promo_codes,
                      :offer, :url, :evidence, :evidence_episode_slug, :evidence_episode_title, :confidence)

    NEWEST = "sponsor_mentions.published_at DESC NULLS LAST, sponsor_mentions.id DESC".freeze
    AGGREGATES = <<~SQL.squish.freeze
      COUNT(DISTINCT sponsor_mentions.episode_id) AS history_episodes_count,
      MIN(sponsor_mentions.published_at) AS history_first_seen,
      MAX(sponsor_mentions.published_at) AS history_last_seen,
      ARRAY_REMOVE(ARRAY_AGG(sponsor_mentions.promo_code ORDER BY #{NEWEST}), NULL) AS history_promo_codes,
      (ARRAY_REMOVE(ARRAY_AGG(sponsor_mentions.offer ORDER BY #{NEWEST}), NULL))[1] AS history_offer,
      (ARRAY_REMOVE(ARRAY_AGG(sponsor_mentions.url ORDER BY #{NEWEST}), NULL))[1] AS history_url,
      (ARRAY_AGG(sponsor_mentions.evidence ORDER BY sponsor_mentions.evidence IS NULL, #{NEWEST}))[1] AS history_evidence,
      (ARRAY_AGG(episodes.slug ORDER BY sponsor_mentions.evidence IS NULL, #{NEWEST}))[1] AS history_episode_slug,
      (ARRAY_AGG(episodes.title ORDER BY sponsor_mentions.evidence IS NULL, #{NEWEST}))[1] AS history_episode_title,
      MAX(sponsor_mentions.confidence) AS history_confidence
    SQL
    RECENT_FIRST = Arel.sql("MAX(sponsor_mentions.published_at) DESC NULLS LAST, COUNT(DISTINCT sponsor_mentions.episode_id) DESC")
    JOINS = "INNER JOIN episodes ON episodes.id = sponsor_mentions.episode_id".freeze

    module_function

    def for(podcast, limit: nil)
      return [] unless podcast&.id

      brands = Brand.joins(:sponsor_mentions).joins(JOINS).where(sponsor_mentions: { podcast_id: podcast.id })
                    .group("brands.id").select("brands.*", AGGREGATES).order(RECENT_FIRST, "brands.id").limit(limit)
      brands.map { |brand| row(brand, brand: brand, podcast: podcast) }
    end

    # podcasts: narrows the shows (a Podcast scope, like the pages' listed ones); removed podcasts never count.
    def for_brand(brand, limit: nil, podcasts: Podcast.all)
      return [] unless brand&.id

      found = sponsored(podcasts).where(sponsor_mentions: { brand_id: brand.id }).group("podcasts.id")
                                 .select("podcasts.*", AGGREGATES).order(RECENT_FIRST, "podcasts.id").limit(limit)
      found.map { |podcast| row(podcast, brand: brand, podcast: podcast) }
    end

    # Rows for every (brand, podcast) pair among brands, in one query; brands is records (or ids, and then each row's
    # brand is nil).
    def for_brands(brands, podcasts: Podcast.all)
      records = Array(brands).select { |b| b.is_a?(Brand) }.index_by(&:id)
      ids = Array(brands).map { |b| b.is_a?(Brand) ? b.id : b }.compact.uniq
      return [] if ids.empty?

      found = sponsored(podcasts).where(sponsor_mentions: { brand_id: ids }).group("podcasts.id", "sponsor_mentions.brand_id")
                                 .select("podcasts.*", "sponsor_mentions.brand_id AS history_brand_id", AGGREGATES)
                                 .order(RECENT_FIRST, "podcasts.id")
      found.map { |podcast| row(podcast, brand: records[podcast[:history_brand_id]], podcast: podcast) }
    end

    def sponsored(podcasts)
      podcasts.joins(:sponsor_mentions).joins(JOINS).where.not(status: "removed")
    end
    private_class_method :sponsored

    def row(record, brand:, podcast:)
      Row.new(brand: brand, podcast: podcast, brand_id: brand&.id || record[:history_brand_id], podcast_id: podcast.id,
              episodes_count: record[:history_episodes_count].to_i, first_seen: record[:history_first_seen],
              last_seen: record[:history_last_seen], promo_codes: Array(record[:history_promo_codes]).uniq.first(CODES),
              offer: record[:history_offer], url: record[:history_url], evidence: record[:history_evidence],
              evidence_episode_slug: record[:history_episode_slug], evidence_episode_title: record[:history_episode_title],
              confidence: record[:history_confidence])
    end
    private_class_method :row
  end
end
