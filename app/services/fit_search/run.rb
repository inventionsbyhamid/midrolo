class FitSearch
  # The brand-side agent (build spec L6, plan section 1b): finds the podcasts a brand's customers love on Qloo, joins
  # them with who already sponsors them (sponsor history read from feeds), their rates and how far their numbers can
  # be trusted, and ranks them. Deterministic steps, each logged through Research::StepLogger for the live trace a
  # report has.
  #
  #   1. find_brand       Qloo search for the brand (or its profile from the last 7 days): tags, competitors,
  #                       complementary brands, categories.
  #   2. qloo_podcasts    Qloo insights for podcasts with the brand as the signal (its categories' tags when Qloo
  #                       doesn't know it), matched to the catalog by entity id; the top unmatched ones are added.
  #   3. category_scores  Qloo affinity for at most 100 catalog shows in the brand's categories that step 2 didn't
  #                       return, plus shows open to sponsors there that Qloo doesn't know.
  #   4. proof            Sponsor history of the brand, its Qloo competitors and complementary brands, and (when Qloo
  #                       listed few) brands Qloo puts in its category, resolved with Brand.find_existing only.
  #   5. price_trust      Each show's lowest rate against the budget, and the trust of its downloads number.
  #   6. rank             Scores (FitSearch::Scoring) and reasons: the tastes the brand and the show share on Qloo
  #                       (never compare, R105), the Qloo rank, the category.
  #   7. summary          A three-bullet brief (FitSearch::Summary).
  #
  # Qloo calls: at most 6 planned (search, recommend, affinity in 2 chunks, category brands, audience tastes), every
  # answer cached by the adapter (7 days, 30 for search); the run's hard ceiling is HARD_TASTE_CALLS. Only steps 1's
  # lookup is required: a later Qloo failure leaves a warning on its step and the search finishes with what it has.
  class Run
    HARD_TASTE_CALLS = 10
    SOFT_TASTE_CALLS = 8
    RECOMMEND_TAKE = 50
    POPULARITY_MAX = 0.9
    LAZY_ADD_LIMIT = 10
    CATEGORY_CANDIDATES = 100
    OPEN_WITHOUT_TASTE = 20
    PROOF_BRANDS = 15
    PROOF_ONLY = 20
    FEW_RIVALS = 5
    PEERS_TAKE = 15
    AUDIENCE_TAGS = 25
    RESULTS_LIMIT = 25
    REASON_TAGS = 3
    PROOF_SHOWN = 5
    HIDDEN_STATUSES = %w[removed failed].freeze

    FAILURE_MESSAGE = "Something went wrong with this search. Try again.".freeze
    BUSY_MESSAGE = "Taste data is busy right now. Try again later.".freeze
    FREE_BUSY_MESSAGE = "Brand searches are busy today. Try again tomorrow.".freeze
    UNAVAILABLE_MESSAGE = "Qloo is unavailable right now. Try again in a few minutes.".freeze

    Candidate = Struct.new(:podcast, :entity, :affinity, :qloo_rank, :category_match, :proof, :price_fit, :score,
                           keyword_init: true)

    def self.call(search) = new(search).call

    def initialize(search, taste: Taste::Provider.current)
      @search = search
      @taste = taste
      @log = Research::StepLogger.new(search, max_taste_calls: SOFT_TASTE_CALLS, hard_taste_calls: HARD_TASTE_CALLS)
      @candidates = {}
      @qloo_count = 0
      @profile = nil
    end

    # Ends the search done, or failed with a message the brand can read. Returns the search.
    def call
      Taste::CallGuard.lane(lane) { run_steps }
      AppSettings.reset_taste_auth_failures!
      finish!
    rescue Taste::AuthError => e
      AppSettings.record_taste_auth_failure!
      fail_with(e, FAILURE_MESSAGE)
    rescue Taste::FreeShareSpent
      fail_with(nil, FREE_BUSY_MESSAGE)
    rescue Taste::RateLimited, Taste::RunBudgetSpent => e
      fail_with(e.is_a?(Taste::CallCapReached) ? nil : e, BUSY_MESSAGE)
    rescue Taste::Error => e
      fail_with(e, UNAVAILABLE_MESSAGE)
    end

    private

    attr_reader :search, :taste, :log

    def run_steps
      find_brand
      qloo_podcasts
      category_scores
      proof
      price_and_trust
      rank
      summarize
    end

    # ---- 1. the brand on Qloo ----

    def find_brand
      log.step("find_brand", "Finding #{query} on Qloo…", input: query) do |step|
        if subject_brand&.qloo_profile_fresh?
          @profile = subject_brand.qloo_profile
          step.output_summary = "Reused #{@profile['name']}'s Qloo profile from #{subject_brand.qloo_profile_fetched_at.to_date.to_fs(:long)}, so no new lookup."
        elsif (entity = pick(taste.search(query: query, types: [ :brand ], take: 5)))
          @profile = BrandProfile.from_entity(entity)
          subject_brand&.store_qloo_profile!(@profile)
          step.output_summary = profile_summary
        else
          step.warn!("Qloo doesn't know #{query} by name, so this search uses your categories' tastes.")
        end
        search.update!(qloo_brand_entity_id: entity_id, categories: brand_categories)
      end
    end

    # The result named like the query (or at the brand's website): Qloo's search is fuzzy and answers the nearest
    # names, so a near miss is no match.
    def pick(entities)
      domain = Brand.normalize_domain(search.website)
      entities.find { |e| Research::Names.same?(e.name, query) } ||
        (domain && entities.find { |e| Brand.normalize_domain(e.website) == domain }) ||
        entities.find { |e| Research::Names.close?(e.name, query) }
    end

    def profile_summary
      rivals = qloo_names("competitors")
      text = "Found #{@profile['name']} on Qloo"
      text += " in #{Copy.and_list(@profile['categories'])}" if @profile["categories"].present?
      text += ". Competitors on Qloo: #{Copy.and_list(rivals.first(4))}" if rivals.any?
      "#{text}."
    end

    # ---- 2. podcasts Qloo links to the brand's audience ----

    def qloo_podcasts
      log.step("qloo_podcasts", "Asking Qloo which podcasts #{audience} love…", input: signal_input) do |step|
        next step.warn!("Nothing to ask Qloo with. Pick a category on your next search.") if signals.empty?

        entities = step.optional("Podcast recommendations") do
          taste.recommend(type: :podcast, **signals, take: RECOMMEND_TAKE, popularity_max: POPULARITY_MAX)
        end
        next unless entities

        entities = entities.select { |e| e.id.present? }
        @qloo_count = entities.size
        known = Podcast.where(qloo_entity_id: entities.map(&:id)).index_by(&:qloo_entity_id)
        added = lazy_add(entities.reject { |e| known.key?(e.id) }.first(LAZY_ADD_LIMIT), step)
        entities.each_with_index do |entity, index|
          podcast = known[entity.id] || added[entity.id]
          add(podcast, entity: entity, affinity: entity.affinity, qloo_rank: index + 1)
        end
        in_catalog = known.values.count { |p| visible?(p) }
        step.output_summary = "Qloo linked #{entities.size} podcasts to this audience: #{in_catalog} in the catalog, #{added.size} added now."
      end
    end

    # The one matcher for Qloo podcasts (Catalog::QlooMatch, lane L1) finds or adds each one; a show it can't place
    # is left out. A failure on one show never fails the search.
    def lazy_add(entities, step)
      entities.each_with_object({}) do |entity, added|
        podcast = ::Catalog::QlooMatch.call(entity)
        next unless podcast && visible?(podcast)

        podcast.link_qloo_entity!(entity.id) if podcast.qloo_entity_id.blank?
        added[entity.id] = podcast
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { fit_search_id: search.id, while: "adding a Qloo podcast" })
        step.warn!("Some shows couldn't be added to the catalog just now.")
      end
    end

    # ---- 3. catalog shows in the brand's categories ----

    def category_scores
      label = brand_categories.any? ? "Scoring shows in #{Copy.and_list(brand_categories)} that Qloo didn't list…" : "Scoring shows in your categories…"
      log.step("category_scores", label, input: podcast_categories.join(", ").presence) do |step|
        next step.warn!("No categories to look in, so this step was skipped.") if podcast_categories.empty?

        scope = Podcast.where.not(status: HIDDEN_STATUSES).where.not(id: @candidates.keys)
                       .where("podcasts.categories ?| array[:names]", names: podcast_categories)
        pool = scope.where.not(qloo_entity_id: nil)
                    .order(open_to_sponsors: :desc, indexable: :desc)
                    .order(Podcast.arel_table[:qloo_popularity].desc.nulls_last).order(:id)
                    .limit(CATEGORY_CANDIDATES).to_a
        scores = {}
        if pool.any? && signals.any?
          scores = step.optional("Taste scores") do
            taste.affinity_for(candidate_ids: pool.map(&:qloo_entity_id), **signals, type: :podcast)
          end || {}
        end
        pool.each { |podcast| add(podcast, affinity: scores[podcast.qloo_entity_id], category_match: true) }
        open = scope.where(qloo_entity_id: nil, open_to_sponsors: true).order(claimed_at: :desc, id: :desc)
                    .limit(OPEN_WITHOUT_TASTE).to_a
        open.each { |podcast| add(podcast, category_match: true) }
        step.output_summary = "Scored #{pool.size} shows; Qloo had a score for #{scores.values.compact.size}. " \
                              "#{open.size} more are open to sponsors without Qloo data."
      end
    end

    # ---- 4. who already sponsors these shows ----

    def proof
      log.step("proof", "Checking which brands like yours already sponsor these shows…") do |step|
        links = proof_links(step)
        rows = Proof.call(links)
        rows.each { |podcast_id, list| @candidates[podcast_id]&.proof = list }
        add_proof_only(rows)
        brands = rows.values.flatten.map { |row| row["brand"] }.uniq
        shows = rows.keys.count { |id| @candidates.key?(id) }
        step.output_summary = if brands.any?
          "#{Copy.and_list(brands.first(4))}#{" and #{brands.size - 4} more" if brands.size > 4} sponsor #{shows} of these shows."
        else
          "Checked #{links.size} brands like yours; none sponsors a show in the catalog yet."
        end
      end
    end

    # [[Brand, relation]]: the brand itself, then Qloo's competitors and complementary brands, then (when those are
    # few) brands Qloo puts in the brand's category. Only brands the catalog already knows; none is created.
    def proof_links(step)
      names = { "competitor" => qloo_names("competitors"), "complementary" => qloo_names("complementary") }
      names["category"] = category_brands(step) if names.values.sum(&:size) < FEW_RIVALS
      links = subject_brand ? [ [ subject_brand, "you" ] ] : []
      names.each do |relation, list|
        list.each do |name|
          brand = Brand.find_existing(name: name)
          links << [ brand, relation ] if brand && brand.id != subject_brand&.id
        end
      end
      links.uniq { |brand, _| brand.id }.first(PROOF_BRANDS)
    end

    def category_brands(step)
      return [] if brand_categories.empty? || signals.empty?

      tag = Categories.tag_id_for(brand_categories.first)
      found = step.optional("Brands in #{brand_categories.first}") do
        taste.recommend(type: :brand, **signals, filter_tags: [ tag ], take: PEERS_TAKE)
      end
      Array(found).map(&:name).reject { |name| Research::Names.same?(name, query) }
    end

    # Shows only the sponsor history found: the strongest proof first.
    def add_proof_only(rows)
      ids = rows.keys.reject { |id| @candidates.key?(id) }
                .sort_by { |id| [ -Scoring.proof_points(rows[id]), id ] }.first(PROOF_ONLY)
      Podcast.where(id: ids).where.not(status: HIDDEN_STATUSES).find_each { |podcast| add(podcast, proof: rows[podcast.id]) }
    end

    # ---- 5. price and trust ----

    def price_and_trust
      log.step("price_trust", "Checking rates, open months and verified numbers…", input: budget_input) do |step|
        @candidates.each_value do |c|
          c.price_fit = Scoring.price_fit(price_cents: c.podcast.min_price_cents, budget_cents: search.budget_cents)
        end
        list = @candidates.values
        open = list.count { |c| c.podcast.open_to_sponsors? }
        within = list.count { |c| c.price_fit == "within" }
        verified = list.count { |c| c.podcast.downloads_trust == "verified" }
        step.output_summary = "#{open} open to sponsors, #{within} within your budget, #{verified} with verified numbers."
      end
    end

    # ---- 6. scores and reasons ----

    def rank
      log.step("rank", "Ranking shows and writing why each one fits…") do |step|
        audience_tags = entity_id ? step.optional("Audience tastes") { taste.taste_tags(entity_ids: [ entity_id ], take: AUDIENCE_TAGS) } : nil
        @brand_tags = BrandProfile.tags(@profile) + Array(audience_tags)
        @candidates.each_value do |c|
          c.score = Scoring.call(affinity: c.affinity, category_match: c.category_match, proof: c.proof,
                                 price_fit: c.price_fit, trust: c.podcast.downloads_trust, claimed: c.podcast.claimed?)
        end
        top = @candidates.values.sort_by { |c| [ -c.score.total, -(c.affinity || 0), c.podcast.id ] }.first(RESULTS_LIMIT)
        save_results(top)
        step.output_summary = "Ranked #{@candidates.size} shows and kept the best #{top.size}."
      end
    end

    def save_results(top)
      now = Time.current
      rows = top.each_with_index.map do |c, index|
        { fit_search_id: search.id, podcast_id: c.podcast.id, position: index + 1, score: c.score.total,
          taste_score: c.affinity, reasons: reasons_for(c), price_fit: c.price_fit, created_at: now, updated_at: now,
          proof: { "brands" => Array(c.proof).first(PROOF_SHOWN), "points" => c.score.parts,
                   "category_match" => c.category_match, "qloo_rank" => c.qloo_rank }.compact }
      end
      FitResult.transaction do
        search.results.delete_all
        FitResult.insert_all!(rows) if rows.any?
      end
    end

    def reasons_for(candidate)
      reasons = []
      if candidate.qloo_rank
        reasons << "Qloo ranks it ##{candidate.qloo_rank} of #{@qloo_count} podcasts for #{audience}."
      elsif candidate.affinity
        reasons << "Qloo taste match for #{audience}: #{(candidate.affinity * 100).round} out of 100."
      end
      shared = shared_tastes(candidate)
      reasons << "Shared tastes on Qloo: #{Copy.and_list(shared)}." if shared.any?
      categories = Array(candidate.podcast.categories) & podcast_categories
      reasons << "In your categories: #{Copy.and_list(categories.first(2))}." if categories.any?
      reasons << "No Qloo taste data for this show yet." if candidate.affinity.nil?
      reasons
    end

    # The taste tags the show's Qloo entity shares with the brand (its own tags and its audience's), by id or name.
    def shared_tastes(candidate)
      return [] unless candidate.entity

      ids = @brand_tags.map(&:id).to_set
      keys = @brand_tags.map { |tag| Research::Names.normalize(tag.name) }.to_set
      Array(candidate.entity.tags).select { |tag| ids.include?(tag.id) || keys.include?(Research::Names.normalize(tag.name)) }
                                  .map(&:name).compact_blank.uniq.first(REASON_TAGS)
    end

    # ---- 7. the brief ----

    def summarize
      log.step("summary", "Writing your brief…") do |step|
        results = search.results.includes(:podcast).to_a
        bullets, how = Summary.call(search, summary_facts(results))
        search.update!(summary: bullets.join("\n"))
        step.output_summary = how == :llm ? "Written from the facts above." : "Written from a template."
      end
    end

    def summary_facts(results)
      Summary::Facts.new(
        brand_name: @profile&.dig("name").presence || query, found_on_qloo: entity_id.present?, qloo_count: @qloo_count,
        results: results, proof_brands: results.flat_map { |r| Array(r.proof["brands"]).pluck("brand") }.uniq,
        within_budget: results.count { |r| r.price_fit == "within" },
        open_count: results.count { |r| r.podcast.open_to_sponsors? },
        verified_count: results.count { |r| r.podcast.downloads_trust == "verified" }
      )
    end

    # ---- shared ----

    def add(podcast, entity: nil, affinity: nil, qloo_rank: nil, category_match: false, proof: nil)
      return unless podcast && visible?(podcast)

      candidate = (@candidates[podcast.id] ||= Candidate.new(podcast: podcast, category_match: false))
      candidate.entity ||= entity
      candidate.affinity ||= affinity
      candidate.qloo_rank ||= qloo_rank
      candidate.category_match ||= category_match || (Array(podcast.categories) & podcast_categories).any?
      candidate.proof ||= proof
    end

    def visible?(podcast) = !HIDDEN_STATUSES.include?(podcast.status)

    def query = search.query.to_s.squish

    # The catalog's brand this search is about: the searcher's own brand when the query names it, else one the catalog
    # already knows by that name or website (an agency searching for a client). Never created here.
    def subject_brand
      return @subject_brand if defined?(@subject_brand)

      own = search.brand
      @subject_brand = if own && Research::Names.close?(own.name, query) then own
      else Brand.find_existing(name: query, domain: search.website)
      end
    end

    def entity_id = @profile&.dig("entity_id").presence

    def qloo_names(list) = Array(@profile&.dig(list)).filter_map { |row| row["name"] if row.is_a?(Hash) }

    # The brand's categories: those the searcher picked, then Qloo's.
    def brand_categories
      @brand_categories ||= Categories.known(Array(search.categories) + Array(@profile&.dig("categories")))
                                      .first(Categories::MAX_BRAND_CATEGORIES)
    end

    def podcast_categories = @podcast_categories ||= Categories.podcast_categories_for(brand_categories)

    # Qloo's signal for this brand: its entity, else its categories' brand tags.
    def signals
      return { entity_ids: [ entity_id ] } if entity_id
      return { tag_ids: brand_categories.map { |name| Categories.tag_id_for(name) } } if brand_categories.any?

      {}
    end

    def audience
      name = @profile&.dig("name").presence
      name ? "#{name}'s customers" : "people into #{Copy.and_list(brand_categories.presence || [ 'your categories' ])}"
    end

    def signal_input
      entity_id ? "#{@profile['name']} on Qloo" : brand_categories.join(", ").presence
    end

    def budget_input
      search.budget_cents.to_i.positive? ? "Budget: $#{search.budget_cents / 100} per episode" : "No budget given"
    end

    def lane = Entitlements.for(search.user).capped_taste? ? :capped : nil

    def finish!
      search.update!(status: "done", finished_at: Time.current, cost_usd: search.spend_entries.sum(:cost_usd))
      FitSearch::Broadcast.refresh(search)
      search
    end

    def fail_with(error, message)
      Rails.error.report(error, handled: true, context: { fit_search_id: search.id }) if error
      search.update!(status: "failed", finished_at: Time.current, error_message: message)
      FitSearch::Broadcast.refresh(search)
      search
    end
  end
end
