module Matching
  # Deterministic, explainable fit score (0..100) for candidate brands.
  class Score
    PROVEN_WINDOW = 90.days

    def self.call(candidates, downloads:, now: Time.current)
      new(candidates, downloads: downloads, now: now).call
    end

    def initialize(candidates, downloads:, now:)
      @candidates = candidates
      @downloads = downloads
      @now = now
      @config = Rails.application.config_for(:scoring)
    end

    def call
      max_affinity = @candidates.map { |c| c.affinity.to_f }.max.to_f
      max_shared = @candidates.map { |c| c.shared_tag_count.to_i }.max.to_i

      @candidates
        .map { |c| Scored.new(candidate: c, fit_score: fit_score(c, max_affinity, max_shared), tier: Tier.for(c.entity.popularity)) }
        .sort_by { |s| [ -s.fit_score, -s.candidate.affinity.to_f ] }
    end

    private

    def fit_score(candidate, max_affinity, max_shared)
      w = @config[:weights]
      affinity_norm = max_affinity.positive? ? candidate.affinity.to_f / max_affinity : 0
      shared_norm = max_shared.positive? ? candidate.shared_tag_count.to_i / max_shared.to_f : 0

      weighted = w[:affinity] * affinity_norm +
                 w[:proven] * proven_weight(candidate.proven_evidence) +
                 w[:shared_tags] * shared_norm +
                 w[:category] * (candidate.category_match ? 1 : 0)

      (100 * weighted - small_show_penalty(candidate.entity.popularity)).clamp(0, 100).round
    end

    # evidence: {items: [{show:, episode_title:, published_at:}], count:} (see Matching::Candidate), in memory
    # or back from jsonb, or nil.
    def proven_weight(evidence)
      items = Evidence.items(evidence)
      return 0 if items.empty?

      cutoff = @now - PROVEN_WINDOW
      items.any? { |e| (published = Evidence.published_at(e)) && published >= cutoff } ? 1.0 : 0.5
    end

    def small_show_penalty(popularity)
      cfg = @config[:small_show]
      return 0 unless @downloads.nil? || @downloads < cfg[:downloads_below]

      floor = cfg[:popularity_floor]
      cfg[:penalty_points] * [ 0, popularity.to_f - floor ].max / (1 - floor)
    end
  end
end
