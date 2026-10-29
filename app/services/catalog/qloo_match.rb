module Catalog
  # The one way to turn a Qloo podcast entity into a catalog podcast (L1's seed, L6's fit search and L8's similar shows
  # all use it). In order:
  #
  # 1. the podcast already linked to the entity id;
  # 2. a catalog podcast with the same title key (Podcast.title_key_for) and no Qloo link yet, when exactly one fits:
  #    its author is close to the entity's (Research::Names.close?), or the entity names no author;
  # 3. with directory: true (the default), a Podcasts::Directory.current search by the entity's name, the same rule
  #    over its hits, and the hit found or created as a podcast (Catalog::NewPodcast, its ingest queued at priority).
  #
  # A match is linked to the entity (Podcast#link_qloo_entity!, which leaves an id another podcast holds alone) and
  # takes its popularity. Returns the podcast, or nil. A plain id (no name) only finds an already linked podcast. The
  # directory being down is a nil, never an error.
  #
  #   Catalog::QlooMatch.call(entity)                      # L6, L8: may add the show to the catalog
  #   Catalog::QlooMatch.call(entity, directory: false)    # the catalog only, no outside call
  class QlooMatch
    # The entity properties Qloo may name a podcast's maker in, first found wins.
    AUTHOR_KEYS = %w[author channel publisher creator host].freeze
    MAX_CANDIDATES = 5
    DIRECTORY_LIMIT = 10

    # before_directory_call: called before each directory search (the seed paces them with it). english_only: skip
    # directory hits in another language.
    def self.call(entity, directory: true, source: "search", priority: :normal, english_only: false,
                  before_directory_call: nil)
      new(entity, directory:, source:, priority:, english_only:, before_directory_call:).call
    end

    def initialize(entity, directory:, source:, priority:, english_only:, before_directory_call:)
      @entity = entity
      @directory = directory
      @source = source
      @priority = priority
      @english_only = english_only
      @before_directory_call = before_directory_call
    end

    def call
      id = (@entity.respond_to?(:id) ? @entity.id : @entity).to_s.strip
      return nil if id.empty?

      linked = Podcast.find_by(qloo_entity_id: id)
      return linked if linked

      key = Podcast.title_key_for(name)
      return nil if key.blank?

      podcast = local_match(key) || (directory_match(key) if @directory)
      link(podcast, id) if podcast
    end

    private

    def name = @entity.respond_to?(:name) ? @entity.name.to_s : ""

    def author
      properties = @entity.respond_to?(:properties) ? @entity.properties.to_h : {}
      AUTHOR_KEYS.lazy.map { |key| properties[key] }.find { |value| value.is_a?(String) && value.strip.present? }
    end

    def local_match(key)
      candidates = Podcast.where(title_key: key, qloo_entity_id: nil).where.not(status: "removed").limit(MAX_CANDIDATES).to_a
      only(candidates, &:author)
    end

    def directory_match(key)
      @before_directory_call&.call
      hits = Podcasts::Directory.current.search(name, limit: DIRECTORY_LIMIT)
      hits = hits.select { |hit| hit.feed_url.present? && Podcast.title_key_for(hit.title) == key }
      hits = hits.select { |hit| NewPodcast.english?(hit) } if @english_only
      hit = only(hits, &:author)
      podcast, = NewPodcast.find_or_create(hit, source: @source, priority: @priority) if hit
      podcast unless podcast.nil? || podcast.removed?
    rescue Podcasts::Directory::Unavailable => e
      Rails.logger.warn("[Catalog::QlooMatch] directory unavailable: #{e.message}")
      nil
    end

    # The one candidate whose author is close to the entity's; without an entity author, the only candidate there is.
    # Several directory entries for one show (the same title and author) take the first, the directory's best.
    def only(candidates, &author_of)
      maker = author
      return candidates.find { |candidate| Research::Names.close?(maker, author_of.call(candidate).to_s) } if maker

      candidates.first if candidates.one?
    end

    def link(podcast, id)
      podcast.link_qloo_entity!(id)
      popularity = @entity.respond_to?(:popularity) ? @entity.popularity : nil
      podcast.update!(qloo_popularity: popularity) if popularity && podcast.qloo_entity_id == id && podcast.qloo_popularity != popularity
      podcast
    end
  end
end
