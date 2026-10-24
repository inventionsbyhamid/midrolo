module Research
  # Shared state for one research run: the providers, the show's feed, the step log (which also tracks the
  # run's taste-call budget), every taste entity and tag a tool has returned (for the provenance checks on
  # save), the audience's taste tags (for scoring), and what the tools have produced so far: the saved seeds,
  # the scored sponsor candidates and the shared-taste explanations.
  # No business logic lives here.
  class Toolkit
    FEED_EPISODES = 15
    BRAND_REF = /\Ab\d+\z/

    attr_reader :report, :seen_entity_ids, :log, :feed_reader
    # [Taste::Tag] saved by AudienceProfile; SponsorCandidates counts shared tags against them.
    attr_reader :audience_tags
    # {entities: [Taste::Entity], tags: [Taste::Tag]} as last saved by SaveTasteSeeds, or nil.
    attr_accessor :seeds
    # {brand_id => Matching::Scored} from FindSponsorCandidates (fit order), and
    # {brand_id => [Taste::Tag]} from ExplainMatches.
    attr_reader :scored, :explanations
    # What the seed lookups learned along the way: {seed_id => source} and the names Qloo couldn't match.
    attr_reader :lookup_sources, :unresolved

    def initialize(report, taste: nil, directory: nil, feed_reader: Podcasts::FeedReader.new,
                   max_taste_calls: StepLogger.configured_max_taste_calls)
      @report = report
      @taste = taste
      @directory = directory
      @feed_reader = feed_reader
      @seen_entity_ids = Set.new
      @entities = {}
      @tags = {}
      @log = StepLogger.new(report, max_taste_calls: max_taste_calls)
      @audience_tags = []
      @scored = {}
      @brand_refs = {}
      @explanations = {}
      @lookup_sources = {}
      @unresolved = []
    end

    def show = report.show
    def user = show.user
    def taste = @taste ||= Taste::Provider.current
    def directory = @directory ||= Podcasts::Directory.current

    # Uncached taste calls this run has made (R31), and whether its soft budget is spent.
    def taste_calls = log.uncached_calls
    def over_taste_budget? = log.budget_spent?

    def feed
      @feed ||= if show.feed_url.present?
        feed_reader.read(show.feed_url, max_episodes: FEED_EPISODES)
      else
        Podcasts::Feed.unreadable
      end
    end

    # Accepts Taste::Entity objects or plain ids. Entity objects are also kept for lookups by id.
    def remember(entities)
      Array(entities).each do |e|
        id = (e.respond_to?(:id) ? e.id : e).to_s
        @seen_entity_ids << id
        @entities[id] ||= e if e.respond_to?(:name)
      end
      self
    end

    def remember_tags(tags)
      Array(tags).each { |t| @tags[t.id.to_s] ||= t }
      self
    end

    def entity(id) = @entities[id.to_s]
    def tag(id) = @tags[id.to_s]

    def audience_tags=(tags)
      @audience_tags = Array(tags)
      @audience_tag_index = nil
      remember_tags(@audience_tags)
    end

    # Merges the results of a seed lookup (Seeds.from_lookup or .deterministic).
    def record_lookup(result)
      remember(result[:entities])
      remember_tags(result[:tags])
      result[:sources].to_h.each { |id, source| @lookup_sources[id.to_s] ||= source }
      @unresolved |= Array(result[:unresolved])
      self
    end

    def seed_entity_ids = Array(seeds&.dig(:entities)).map(&:id)
    def seed_tag_ids = Array(seeds&.dig(:tags)).map(&:id)
    def seed_count = seed_entity_ids.size + seed_tag_ids.size

    # Adds scored candidates (fit order) and gives each new brand a short ref ("b1", "b2"…) the model can
    # use instead of a long Qloo id. A brand keeps its ref for the whole run.
    def add_candidates(scored_list)
      scored_list.each do |s|
        id = s.candidate.entity.id
        @scored[id] = s
        @brand_refs[id] ||= "b#{@brand_refs.size + 1}"
      end
      self
    end

    def brand_ref(brand_id) = @brand_refs[brand_id.to_s]

    # The brand id for a ref ("b3") or an id, when that brand is a scored candidate of this run; else nil.
    def resolve_brand(key)
      key = key.to_s.strip
      id = key.match?(BRAND_REF) ? @brand_refs.key(key) : key
      id if id && @scored.key?(id)
    end

    def add_explanations(explained)
      @explanations.merge!(explained)
      self
    end

    # R27: the brand's tags that the audience also has, by id or else by name. Uses the audience tags of
    # this run, or the ones already saved on the report.
    def shared_audience_tags(brand)
      ids, names = audience_tag_index
      Array(brand.tags).select { |t| ids.include?(t.id) || names.include?(Names.normalize(t.name)) }
    end

    private

    def audience_tag_index
      @audience_tag_index ||= begin
        pairs = audience_tags.map { |t| [ t.id, t.name ] }.presence || saved_audience_tags
        [ pairs.map(&:first).compact.to_set, pairs.map { |(_, name)| Names.normalize(name) }.reject(&:empty?).to_set ]
      end
    end

    def saved_audience_tags
      tags = report.audience.is_a?(Hash) ? report.audience["tags"] : nil
      Array(tags).filter_map { |t| [ t["id"], t["name"] ] if t.is_a?(Hash) }
    end
  end
end
