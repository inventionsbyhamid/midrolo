module Research
  # The research playbook without an LLM: the same services in the agent's order, saving through the same
  # tools, with deterministic choices (Seeds.deterministic, config/category_map.yml, the top candidates).
  #   with_reasons: true  — a full report in fake-LLM mode: every section, templated reasons and summary.
  #   with_reasons: false — a free Snapshot (R36): seeds, taste tags, the map and unreasoned matches only; no
  #                         demographics, no proven-sponsor scan (scan_limit 0), no summary, and no Llm at all.
  # Raises NeedsInput when fewer than 2 seeds are found, or when the seeds find no sponsor candidates (Review
  # Focus #1: never an empty report). Returns the toolkit.
  class ScriptedRunner
    def self.call(report, with_reasons:) = new(report, with_reasons: with_reasons).call

    def initialize(report, with_reasons:)
      @report = report
      @with_reasons = with_reasons
      @toolkit = Toolkit.new(report)
    end

    def call
      save_seeds
      raise NeedsInput, "fewer than 2 taste seeds" if toolkit.seed_count < 2

      AudienceProfile.build(toolkit, seed_entity_ids: toolkit.seed_entity_ids, seed_tag_ids: toolkit.seed_tag_ids,
                                     country: show.country, include_demographics: @with_reasons, entities: @with_reasons)
      scored = SponsorCandidates.find(toolkit, seed_entity_ids: toolkit.seed_entity_ids, seed_tag_ids: toolkit.seed_tag_ids,
                                               categories: CategoryMap.for(show.categories), scan_limit: scan_limit)
      raise NeedsInput, "no sponsor candidates for these seeds" if scored.empty?

      # No model reads a candidate list here, so every candidate counts as shown.
      toolkit.add_candidates(scored).show_candidates(scored.map { |s| s.candidate.entity.id })
      explain(scored) if @with_reasons
      save_matches(scored)
      Tools::SaveSummary.new(toolkit).call(bullets: Templates.summary(toolkit, scored)) if @with_reasons
      toolkit
    end

    private

    attr_reader :toolkit

    delegate :show, to: :toolkit

    # Asks for a direct profile; the tool labels it proxy unless the show itself is a seed.
    def save_seeds
      seeds = Seeds.deterministic(toolkit)
      toolkit.record_lookup(seeds)
      Tools::SaveTasteSeeds.new(toolkit).call(entity_ids: seeds[:entities].map(&:id), tag_ids: seeds[:tags].map(&:id),
                                              profile_kind: "direct", sources: seeds[:sources])
    end

    def scan_limit = @with_reasons ? Entitlements.for(toolkit.user).scan_limit : 0

    # Every match: Qloo compares the first MatchExplainer::MAX_COMPARES when allowed, the rest share tags (R105).
    def explain(scored)
      ids = scored.map { |s| s.candidate.entity.id }
      toolkit.add_explanations(MatchExplainer.call(toolkit, brand_ids: ids, seed_entity_ids: toolkit.seed_entity_ids))
    end

    def save_matches(scored)
      picks = scored.map do |s|
        { brand_id: s.candidate.entity.id, reason: (Templates.reason(toolkit, s) if @with_reasons) }
      end
      Tools::SaveSponsorMatches.new(toolkit, require_reasons: @with_reasons).call(matches: picks)
    end
  end
end
