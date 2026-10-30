module Sponsors
  # Saves a Sponsors::Scan result: each detection's brand (Brand.resolve: by domain, then by name; a new brand takes
  # the model's proper name, an existing one is never renamed), one SponsorMention per episode and brand with the
  # episode's published_at, the episodes marked sponsor_scanned_at (and sponsor_ai_checked_at when the AI-first scan
  # settled them), the touched brands' sponsor_mentions_count recounted, and the podcast touched so its page's cache
  # moves.
  #
  # An episode the model checked has its mentions replaced by this scan's, pattern reads from an older scan included
  # (the unique index on episode and brand keeps one row each); an episode only the patterns read (fake mode) keeps what
  # it had and gains new ones, so a pattern-only run never undoes a model's answer. Returns the mentions written.
  class Record
    def self.call(podcast, result) = new(podcast, result).call

    def initialize(podcast, result)
      @podcast = podcast
      @result = result
      @brands = {}
    end

    def call
      rows = merge(@result.detections.filter_map { |detection| row_for(detection) })
      replaced = @result.checked_episode_ids
      touched = Set.new
      written = 0
      SponsorMention.transaction do
        touched.merge(SponsorMention.where(episode_id: replaced).distinct.pluck(:brand_id))
        removed = SponsorMention.where(episode_id: replaced).delete_all
        if rows.any?
          inserted = SponsorMention.insert_all(rows, unique_by: %i[episode_id brand_id], returning: %w[brand_id])
          touched.merge(inserted.rows.flatten)
          written = inserted.rows.size
        end
        now = Time.current
        Episode.where(id: @result.settled_episode_ids).update_all(sponsor_scanned_at: now, sponsor_ai_checked_at: now)
        Episode.where(id: @result.scanned_episode_ids - @result.settled_episode_ids).update_all(sponsor_scanned_at: now)
        @changed = removed.positive? || written.positive?
      end
      recount(touched)
      @podcast.touch if @changed
      written
    end

    private

    def row_for(detection)
      brand = brand_for(detection)
      return nil unless brand

      episode = detection.episode
      { podcast_id: @podcast.id, episode_id: episode.id, brand_id: brand.id, published_at: episode.published_at,
        promo_code: detection.promo_code&.first(LlmCheck::CODE_LIMIT),
        offer: detection.offer&.truncate(SponsorMention::OFFER_LIMIT, separator: " "),
        url: (detection.url if detection.url.to_s.length <= 2000),
        evidence: detection.evidence&.truncate(SponsorMention::EVIDENCE_LIMIT, separator: " "),
        detected_by: detection.detected_by, confidence: detection.confidence }
    end

    # One brand per name and domain in this scan; a detection whose brand can't be made is skipped.
    def brand_for(detection)
      key = [ detection.domain, Research::ProvenSponsorScan.key_for(detection.name) ]
      return @brands[key] if @brands.key?(key)

      @brands[key] = Brand.resolve(name: detection.name, domain: detection.domain)
    rescue ActiveRecord::RecordInvalid, ArgumentError => e
      Rails.error.report(e, handled: true, context: { podcast_id: @podcast.id, brand: detection.name, domain: detection.domain })
      @brands[key] = nil
    end

    # Two detections of one brand in one episode (a name and a domain that resolved together) become one row.
    def merge(rows)
      rows.group_by { |row| row.values_at(:episode_id, :brand_id) }.map do |_, group|
        best = group.max_by { |row| row[:confidence].to_f }
        group.reduce(best) { |acc, row| acc.merge(row.compact) { |_, mine, theirs| mine.nil? ? theirs : mine } }
      end
    end

    def recount(brand_ids)
      return if brand_ids.empty?

      Brand.where(id: brand_ids.to_a).update_all(<<~SQL.squish)
        sponsor_mentions_count = (SELECT COUNT(*) FROM sponsor_mentions WHERE sponsor_mentions.brand_id = brands.id),
        updated_at = CURRENT_TIMESTAMP
      SQL
    end
  end
end
