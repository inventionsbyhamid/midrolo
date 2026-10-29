module Research
  # Shows with a similar audience (build spec L8): one Qloo podcast recommendation with the show itself as the signal, or
  # the saved seeds when the show isn't on Qloo (a proxy profile), each show then matched to the catalog
  # (Catalog::QlooMatch) and, when the catalog lacks it, added (Catalog::LazyAdd: a pending podcast until its feed is
  # read). Saves the report's similar section, most similar first, never the show itself (build spec section 10):
  #   [{"qloo_entity_id", "name", "score" (Qloo's 0 to 1, or nil), "podcast_id" (the catalog's, or nil)}]
  #
  # One step, run right after the audience profile by both runners (ScriptedRunner, and the agent's
  # build_audience_profile tool). Its Qloo call is core but never fatal: the run's soft budget doesn't skip it, only the
  # hard ceiling (R130) does, and Qloo trouble skips it with a step warning like an optional call. The catalog part is
  # never fatal either: a directory outage stops the adds, and anything else the catalog raises is reported and leaves
  # that show without its page. Returns the saved entries, or nil when the call was skipped (the section keeps what it
  # had).
  class SimilarPodcasts
    # config/research.yml.
    TAKE = Research.caps.fetch(:similar_podcasts)
    MAX_ADDS = Research.caps.fetch(:similar_podcast_adds)
    LOOKUP_FAILED = "Couldn't look some shows up in the catalog".freeze

    def self.call(toolkit) = new(toolkit).call

    # The step for a report that finished before it existed (the sample reports: rake matching:similar_backfill), from
    # the seeds that report saved; its trace gains the step. A background run, so the call guard may wait out the
    # minute cap (R109). Returns what #call does.
    def self.backfill(report)
      saved = report.seeds.is_a?(Hash) ? report.seeds : {}
      rows = ->(key) { Array(saved[key]).select { |row| row.is_a?(Hash) && row["id"].present? } }
      entities = rows.("entities").map do |row|
        Taste::Entity.new(id: row["id"], name: row["name"], type: row["type"]&.to_sym, popularity: nil, affinity: nil,
                          image_url: nil, description: nil, website: nil, tags: [], properties: {})
      end
      tags = rows.("tags").map { |row| Taste::Tag.new(id: row["id"], name: row["name"], type: nil, score: nil) }
      toolkit = Toolkit.new(report)
      toolkit.record_lookup({ entities: entities, tags: tags, sources: rows.("entities").to_h { |row| [ row["id"], row["source"] ] } })
      toolkit.seeds = { entities: entities, tags: tags }
      Taste::CallGuard.waiting { call(toolkit) }
    end

    # The Qloo signals the step asks with: the show's own entity when it is on Qloo, else the saved seeds; nil with
    # neither. The agent's tool runs the step again only when these change.
    def self.signals(toolkit)
      own = own_entity_id(toolkit)
      return { entity_ids: [ own ], tag_ids: [] } if own

      seeds = { entity_ids: toolkit.seed_entity_ids, tag_ids: toolkit.seed_tag_ids }
      seeds if seeds.values.any?(&:present?)
    end

    # The show on Qloo: the entity its podcast is linked to (Seeds links it once found), else a seed found as the show
    # itself (its podcast couldn't take the id because another podcast holds it).
    def self.own_entity_id(toolkit)
      toolkit.show.qloo_entity_id.presence ||
        toolkit.seed_entity_ids.find { |id| toolkit.lookup_sources[id.to_s] == Seeds::SHOW_SOURCE }
    end

    def initialize(toolkit)
      @toolkit = toolkit
      @signals = self.class.signals(toolkit)
      @own_id = self.class.own_entity_id(toolkit).to_s
      @adds = 0
      @counts = Hash.new(0)
    end

    def call
      return nil unless @signals

      log.step("similar_podcasts", "Finding shows with a similar audience…", input: input_line) do |step|
        entities = similar_entities(step)
        next nil unless entities

        entries = entities.filter_map { |entity| entry(entity, step) }
        report.save_section!(:similar, entries)
        step.output_summary = summary(entries)
        entries
      end
    end

    private

    attr_reader :toolkit

    delegate :taste, :log, :report, :show, to: :toolkit, private: true

    def similar_entities(step)
      taste.recommend(type: :podcast, **@signals, take: TAKE)
    rescue Taste::RunBudgetSpent
      step.warn!(StepLogger::BUDGET_WARNING)
    rescue *StepLogger::SOFT_ERRORS => e
      step.warn!("Similar shows skipped: #{StepLogger.describe(e)}")
    end

    def entry(entity, step)
      return nil if own?(entity)

      podcast = catalog_podcast(entity, step)
      return nil if podcast && podcast.id == show.podcast_id

      { "qloo_entity_id" => entity.id.to_s, "name" => entity.name.to_s, "score" => entity.affinity, "podcast_id" => podcast&.id }
    end

    def own?(entity) = entity.id.to_s == @own_id || Names.same?(entity.name, show.title)

    # The catalog's podcast for a similar show: the one Catalog::QlooMatch gives, else one Catalog::LazyAdd finds or adds
    # under the same name. nil when neither has it, past MAX_ADDS adds, or once the directory is down.
    def catalog_podcast(entity, step)
      podcast = ::Catalog::QlooMatch.call(entity)
      return counted(:matched, podcast) if podcast
      return nil if @directory_down || @adds >= MAX_ADDS || entity.name.blank?

      add(entity)
    rescue Podcasts::Directory::Unavailable => e
      @directory_down = true
      step.warn!("Stopped adding shows: #{StepLogger.describe(e)}")
      nil
    rescue Taste::Error
      raise
    rescue StandardError => e
      # The catalog must never fail a report: the show is listed without its page.
      Rails.error.report(e, handled: true, context: { report_id: report.id, qloo_entity_id: entity.id, while: "matching a similar show" })
      step.warn!(LOOKUP_FAILED)
      nil
    end

    # A podcast by the show's exact name (Podcast#title_key) that isn't another entity's, linked to this one.
    def add(entity)
      @adds += 1
      result = ::Catalog::LazyAdd.call(entity.name)
      key = Podcast.title_key_for(entity.name)
      podcast = result.podcasts.find { |p| p.title_key == key && p.qloo_entity_id.to_s.in?([ "", entity.id.to_s ]) }
      return nil unless podcast

      podcast.link_qloo_entity!(entity.id)
      counted(result.added.include?(podcast) ? :added : :matched, podcast)
    end

    def counted(kind, podcast)
      @counts[kind] += 1
      podcast
    end

    def input_line
      return Seeds::SHOW_SOURCE if @own_id.present?

      "#{@signals[:entity_ids].size} entity and #{@signals[:tag_ids].size} tag seeds"
    end

    # "10 shows: 6 on Midrolo, 3 being added"
    def summary(entries)
      return "No similar shows came back" if entries.empty?

      parts = []
      parts << "#{@counts[:matched]} on #{APP_NAME}" if @counts[:matched].positive?
      parts << "#{@counts[:added]} being added" if @counts[:added].positive?
      "#{entries.size} #{'show'.pluralize(entries.size)}: #{parts.any? ? parts.join(', ') : "none on #{APP_NAME} yet"}"
    end
  end
end
