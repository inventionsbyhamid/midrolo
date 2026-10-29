module Catalog
  # The one way to turn a Qloo podcast entity into a catalog podcast (L1's seed, L6's fit search and L8's similar shows
  # all use it). In order:
  #
  # 1. the podcast already linked to the entity id;
  # 2. a catalog podcast with the same title key (Podcast.title_key_for) and no Qloo link yet: the one whose author is
  #    close to the entity's (Research::Names.close?), else the only catalog podcast with that title at all (a
  #    same-titled show already linked elsewhere means the author must match: code review M4);
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

    # A catalog podcast of the entity's title: the first whose author is close to the entity's, directory-listed ones
    # first; else the catalog's only podcast of that title, and only when a directory lists it (podcast_index_id or
    # apple_id). A feed someone added by its URL alone never takes a Qloo identity by its title alone (final review N5).
    def local_match(key)
      titled = Podcast.where(title_key: key).where.not(status: "removed")
      candidates = titled.where(qloo_entity_id: nil).order(Arel.sql("(podcast_index_id IS NULL AND apple_id IS NULL)"), :id)
                         .limit(MAX_CANDIDATES).to_a
      maker = author
      close = maker && candidates.find { |candidate| Research::Names.close?(maker, candidate.author.to_s) }
      return close if close

      lone = candidates.first if candidates.one? && titled.limit(2).count == 1
      lone if lone && (lone.podcast_index_id || lone.apple_id)
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

    # The first candidate whose author is close to the entity's (several directory entries for one show take the
    # directory's best); else the only candidate there is. Qloo's maker field for podcasts isn't documented and may
    # name the network rather than the host, so a lone candidate with an equal title still counts; a title shared by
    # several shows ("The Daily") needs the author.
    def only(candidates, &author_of)
      maker = author
      close = maker && candidates.find { |candidate| Research::Names.close?(maker, author_of.call(candidate).to_s) }
      close || (candidates.first if candidates.one?)
    end

    def link(podcast, id)
      podcast.link_qloo_entity!(id)
      popularity = @entity.respond_to?(:popularity) ? @entity.popularity : nil
      podcast.update!(qloo_popularity: popularity) if popularity && podcast.qloo_entity_id == id && podcast.qloo_popularity != popularity
      podcast
    end
  end
end
