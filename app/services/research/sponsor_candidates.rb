module Research
  # Finds and ranks sponsor candidates for a seed set:
  #   1. a broad brand recommendation (popularity capped, so household names don't crowd the list)
  #   2. one filtered recommendation per brand category the caller picked (the first MAX_CATEGORIES, R93)
  #   3. brands proven to sponsor similar podcasts (ProvenSponsorScan)
  # then scores the merged set with affinity_for and Matching::Score. Returns up to 50 Matching::Scored,
  # one per brand, best first. Every candidate is remembered on the toolkit for the provenance check.
  #
  # The broad recommendation and affinity_for are essential and their errors propagate. A failing
  # category pass is skipped with a step warning.
  class SponsorCandidates
    BROAD_TAKE = 50
    CATEGORY_TAKE = 20
    MAX_CATEGORIES = Research.caps.fetch(:category_passes)
    POPULARITY_MAX = 0.97
    MAX_RESULTS = 50
    BRAND_TAG_TYPE = "urn:tag:genre:brand".freeze
    BRAND_TAG_PREFIX = "#{BRAND_TAG_TYPE}:".freeze

    def self.find(toolkit, seed_entity_ids:, seed_tag_ids:, categories:, scan_limit:)
      new(toolkit, seed_entity_ids, seed_tag_ids, categories, scan_limit).find
    end

    def initialize(toolkit, seed_entity_ids, seed_tag_ids, categories, scan_limit)
      @toolkit = toolkit
      @entity_ids = Array(seed_entity_ids).map(&:to_s).uniq
      @tag_ids = Array(seed_tag_ids).map(&:to_s).uniq
      requested = Array(categories).map { |c| c.to_s.strip }.reject(&:blank?).uniq
      @categories = requested.first(MAX_CATEGORIES)
      @dropped_categories = requested.drop(MAX_CATEGORIES)
      @scan_limit = scan_limit
      @pool = {}
      @category_tag_ids = Set.new
      @evidence = {}
    end

    def find
      return [] if @entity_ids.empty? && @tag_ids.empty?

      broad_pass
      category_passes if @categories.any?
      proven_pass
      toolkit.remember(@pool.values)
      score
    end

    private

    attr_reader :toolkit

    delegate :taste, :log, :report, :show, to: :toolkit, private: true

    def signals = { entity_ids: @entity_ids, tag_ids: @tag_ids }

    def broad_pass
      log.step("find_sponsor_candidates", "Finding brands your audience already loves…",
               input: "#{@entity_ids.size} entity and #{@tag_ids.size} tag seeds") do |step|
        brands = taste.recommend(type: :brand, **signals, popularity_max: POPULARITY_MAX, take: BROAD_TAKE)
        add(brands)
        step.output_summary = brands.empty? ? "No brands came back for these seeds" : "#{brands.size} brands (the biggest household names left out)"
      end
    end

    def category_passes
      log.step("find_sponsor_candidates", "Looking for #{@categories.to_sentence} brands…", input: @categories.join(", ")) do |step|
        counts = @categories.map do |name|
          tag_id = category_tag_id(name, step)
          @category_tag_ids << tag_id
          brands = step.optional("#{name} brands") do
            taste.recommend(type: :brand, **signals, filter_tags: [ tag_id ], take: CATEGORY_TAKE)
          end
          add(brands || [])
          "#{name}: #{brands&.size || 0}"
        end
        dropped = "; searched the first #{MAX_CATEGORIES}, not #{@dropped_categories.to_sentence}" if @dropped_categories.any?
        step.output_summary = "#{counts.join(', ')}#{dropped}"
      end
    end

    # R28: the first brand-genre tag Qloo suggests for the name (looking among brand tags only), else the conventional
    # id, which spells "&" as "and" like Qloo's own ("Food & Beverage" => food_and_beverage, R87).
    def category_tag_id(name, step)
      found = step.optional("#{name} category lookup") { taste.find_tags(query: name, types: [ BRAND_TAG_TYPE ]) }
      Array(found).map(&:id).find { |id| id.start_with?(BRAND_TAG_PREFIX) } ||
        "#{BRAND_TAG_PREFIX}#{name.downcase.gsub('&', ' and ').parameterize(separator: '_')}"
    end

    def proven_pass
      scan = ProvenSponsorScan.new(toolkit, podcast_names: similar_podcasts, limit: @scan_limit)
      @evidence = scan.call
      add(scan.brands.values)
    end

    # The shows the user listed first, then the podcasts the audience profile found.
    def similar_podcasts
      listed = Array(show.hints[:comparable_shows])
      profiled = Array(report.audience.is_a?(Hash) ? report.audience["podcasts"] : nil).filter_map { |p| p["name"] if p.is_a?(Hash) }
      (listed + profiled).map { |n| n.to_s.strip }.reject(&:blank?).uniq { |n| Names.normalize(n) }
    end

    def score
      log.step("score_candidates", "Scoring #{@pool.size} brands for fit…") do |step|
        affinities = taste.affinity_for(candidate_ids: @pool.keys, **signals, type: :brand)
        candidates = @pool.values.map { |brand| candidate(brand, affinities[brand.id]) }
        scored = Matching::Score.call(candidates, downloads: show.downloads_per_episode).first(MAX_RESULTS)
        step.output_summary = score_summary(scored)
        scored
      end
    end

    def candidate(brand, affinity)
      Matching::Candidate.new(entity: brand, affinity: affinity || brand.affinity,
                              proven_evidence: @evidence[brand.id] || Matching::Candidate::NO_EVIDENCE,
                              shared_tag_count: shared_tag_count(brand), category_match: brand.tags.any? { |t| @category_tag_ids.include?(t.id) })
    end

    # R27: tags the brand shares with the audience's taste tags, by id or else by name.
    def shared_tag_count(brand) = toolkit.shared_audience_tags(brand).size

    # Every source asked Qloo for brands only, so no type filter here (Qloo's subtype naming may vary).
    def add(brands)
      brands.each { |brand| @pool[brand.id] ||= brand }
    end

    def score_summary(scored)
      tiers = scored.map(&:tier).tally
      proven = scored.count { |s| Matching::Evidence.count(s.candidate.proven_evidence).positive? }
      parts = { easy_yes: "easy yes", realistic: "realistic", long_shot: "long shot" }.filter_map do |tier, label|
        "#{tiers[tier]} #{label}" if tiers[tier]
      end
      "Ranked #{scored.size} brands: #{parts.join(', ').presence || 'none'}; #{proven} proven podcast #{'sponsor'.pluralize(proven)}"
    end
  end
end
