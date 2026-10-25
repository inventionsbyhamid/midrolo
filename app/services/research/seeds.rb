module Research
  # Picks taste seeds: the Qloo entities and tags that stand in for a show's audience.
  #
  # Both entry points return {entities: [Taste::Entity], tags: [Taste::Tag], unresolved: [String],
  # sources: {seed_id => String}}. "unresolved" lists names and topics that someone typed but Qloo
  # couldn't match. Every entity found is remembered on the toolkit. Qloo errors propagate: without
  # seeds nothing else can run, and an outage must not look like "your show has no seeds".
  class Seeds
    SHOW_SOURCE = "Your show on Qloo".freeze
    HINT_SOURCE = "You listed it".freeze
    LOOKUP_TYPES = %i[podcast artist tv_show movie book brand].freeze
    MEDIA_TAG_TYPE = "urn:tag:genre:media".freeze
    MEDIA_TAG_PREFIX = "#{MEDIA_TAG_TYPE}:".freeze
    MAX_ENTITIES = 8
    MAX_TAGS = 5
    # config/research.yml (R93).
    MAX_LOOKUP_NAMES = Research.caps.fetch(:comparable_show_lookups)
    MAX_LOOKUP_TOPICS = Research.caps.fetch(:topic_lookups)

    def self.from_lookup(toolkit, names:, topics:) = new(toolkit).from_lookup(names, topics)

    # No LLM: the show itself on Qloo, then the shows the user listed, then their topics, then the show's
    # categories as media genre tags. Lookups are capped like from_lookup's (MAX_LOOKUP_NAMES names and
    # MAX_LOOKUP_TOPICS topics), and an unresolved hint still uses up its lookup.
    def self.deterministic(toolkit) = new(toolkit).deterministic

    def initialize(toolkit)
      @toolkit = toolkit
      @entities = {}
      @tags = {}
      @sources = {}
      @unresolved = []
    end

    def from_lookup(names, topics)
      names = distinct(names).first(MAX_LOOKUP_NAMES)
      topics = distinct(topics).first(MAX_LOOKUP_TOPICS)
      log.step("find_on_qloo", "Looking up shows, artists and topics on Qloo…", input: (names + topics).join(", ")) do |step|
        found_names = names.count { |name| add_entity(name, types: LOOKUP_TYPES) { |e| lookup_source(name, e) } }
        found_topics = topics.count { |topic| add_tag(topic, source: "Topic: #{topic}") }
        step.output_summary = "Found #{found_names} of #{names.size} names and #{found_topics} of #{topics.size} topics on Qloo"
      end
      result
    end

    def deterministic
      find_show
      find_comparable_shows
      find_topic_and_category_tags
      result
    end

    private

    attr_reader :toolkit

    delegate :taste, :log, :show, to: :toolkit, private: true

    def find_show
      log.step("find_on_qloo", "Finding your show on Qloo…", input: show.title) do |step|
        hits = taste.search(query: show.title, types: [ :podcast ], take: 5)
        own = hits.find { |e| show.qloo_entity_id.present? && e.id == show.qloo_entity_id } ||
              hits.find { |e| Names.same?(e.name, show.title) }
        add(own, SHOW_SOURCE) if own
        step.output_summary = own ? "Found #{own.name} on Qloo" : "Not on Qloo yet, so we'll use comparable shows and topics"
      end
    end

    def find_comparable_shows
      names = distinct(show.hints[:comparable_shows]).first(MAX_LOOKUP_NAMES)
      return if names.empty?

      log.step("find_on_qloo", "Looking up the shows you listed…", input: names.join(", ")) do |step|
        found = names.count { |name| room_for_entity? && add_entity(name, types: [ :podcast ]) { HINT_SOURCE } }
        step.output_summary = "Found #{found} of #{names.size} shows on Qloo"
      end
    end

    def find_topic_and_category_tags
      topics = distinct(show.hints[:topics]).first(MAX_LOOKUP_TOPICS)
      categories = distinct(show.categories)
      return if topics.empty? && categories.empty?

      log.step("find_tags", "Matching your topics and categories to taste tags…", input: (topics + categories).join(", ")) do |step|
        topics.each { |topic| add_tag(topic, source: "Topic: #{topic}") if room_for_tag? }
        categories.each { |category| add_category_tag(category) if room_for_tag? }
        step.output_summary = @tags.empty? ? "No matching taste tags" : "Matched #{Copy.and_list(@tags.values.map(&:name))}"
      end
    end

    # Searches one name; keeps the first hit whose name is close to it. Returns true when an entity was found.
    def add_entity(name, types:)
      hit = taste.search(query: name, types: types, take: 3).find { |e| Names.close?(name, e.name) }
      return unresolved!(name) unless hit

      add(hit, yield(hit)) unless @entities.key?(hit.id)
      true
    end

    def add_tag(topic, source:)
      tag = taste.find_tags(query: topic, take: 5).first
      return unresolved!(topic) unless tag

      @tags[tag.id] ||= tag
      @sources[tag.id] ||= source
      true
    end

    # Categories only count as media genre tags, so only those are looked up (R87); one with no such tag is skipped (it
    # isn't the user's typo).
    def add_category_tag(category)
      tag = taste.find_tags(query: category, take: 5, types: [ MEDIA_TAG_TYPE ]).find { |t| t.id.start_with?(MEDIA_TAG_PREFIX) }
      return false unless tag

      @tags[tag.id] ||= tag
      @sources[tag.id] ||= "Show category: #{category}"
      true
    end

    def add(entity, source)
      @entities[entity.id] = entity
      @sources[entity.id] = source
    end

    def lookup_source(name, entity)
      if entity.type == :podcast && Names.same?(entity.name, show.title) then SHOW_SOURCE
      elsif distinct(show.hints[:comparable_shows]).any? { |hint| Names.same?(hint, name) } then HINT_SOURCE
      else "Matched \"#{name}\""
      end
    end

    def room_for_entity? = @entities.size < MAX_ENTITIES
    def room_for_tag? = @tags.size < MAX_TAGS

    def unresolved!(text)
      @unresolved << text
      false
    end

    # Stripped, non-blank, first spelling of each name.
    def distinct(list)
      Array(list).map { |s| s.to_s.strip }.reject(&:blank?).uniq { |s| Names.normalize(s) }
    end

    def result
      toolkit.remember(@entities.values)
      { entities: @entities.values, tags: @tags.values, unresolved: @unresolved, sources: @sources }
    end
  end
end
