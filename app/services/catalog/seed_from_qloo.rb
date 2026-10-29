module Catalog
  # Seeds the catalog from Qloo's podcasts (build spec L1): Qloo insights for urn:entity:podcast, one podcast genre tag
  # (urn:tag:genre:media:*) at a time, popularity at most 0.9 so the giants stay out, paged 50 at a time with offset,
  # the tags taken in turn. Each entity is matched to a feed through Catalog::QlooMatch (title key equal, author
  # close, English hits only), with directory searches paced to about one a second; a match is linked to its entity,
  # and a new podcast's ingest is queued at the seed's low priority.
  #
  # Idempotent: an entity already linked is skipped, and one that found no feed is remembered for a week so a re-run
  # doesn't search for it again. Stops once target podcasts are linked to Qloo, when every tag runs out, or when Qloo's
  # call caps say so (Taste::CallGuard; the minute cap is waited out). A tag Qloo doesn't take is dropped.
  #
  #   Catalog::SeedFromQloo.call(target: 1000, log: ->(line) { puts line })
  class SeedFromQloo
    DEFAULT_TARGET = 1000
    TAKE = 50
    POPULARITY_MAX = 0.9
    # Qloo pages through at most this many results of one tag.
    MAX_OFFSET = 2000
    DIRECTORY_INTERVAL = 1.0 # seconds between directory searches
    MISS_TTL = 7.days
    GENRES = %w[business entrepreneurship technology science education news comedy society_culture health_fitness
                self_improvement history sports true_crime arts music religion_spirituality kids_family leisure
                tv_film fiction government].freeze
    TAGS = GENRES.map { |genre| "urn:tag:genre:media:#{genre}" }.freeze

    Result = Data.define(:linked, :added, :matched, :missed, :pages, :stopped)

    def self.call(target: DEFAULT_TARGET, tags: TAGS, log: nil, sleeper: ->(seconds) { sleep(seconds) },
                  clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      new(target:, tags:, log:, sleeper:, clock:).call
    end

    def initialize(target:, tags:, log:, sleeper:, clock:)
      @target = target.to_i
      @tags = tags
      @log = log
      @sleeper = sleeper
      @clock = clock
      @seen = Set.new
      @counts = Hash.new(0)
      @last_directory_call = nil
      @started_at = Time.current
    end

    def call
      stopped = Taste::CallGuard.waiting { seed }
      say("done: #{linked} podcasts linked to Qloo (#{@counts[:matched]} matched this run, #{@counts[:added]} new)")
      Result.new(linked: linked, added: @counts[:added], matched: @counts[:matched], missed: @counts[:missed],
                 pages: @counts[:pages], stopped: stopped)
    end

    private

    # Why it stopped: "target", "exhausted", or the Qloo problem that ended it.
    def seed
      offsets = @tags.index_with(0)
      until offsets.empty?
        offsets.keys.each do |tag|
          return "target" if linked >= @target

          entities = page(tag, offsets[tag])
          offsets[tag] += TAKE
          offsets.delete(tag) if entities.nil? || entities.size < TAKE || offsets[tag] >= MAX_OFFSET
          entities&.each do |entity|
            consider(entity)
            return "target" if linked >= @target
          end
        end
      end
      "exhausted"
    rescue Taste::CallCapReached, Taste::RateLimited => e
      say("stopped: #{e.message}")
      "qloo_limit"
    rescue Taste::AuthError, Taste::MissingCredentials, Taste::Unavailable => e
      say("stopped: #{e.class.name.demodulize}: #{e.message}")
      "qloo_error"
    end

    # One page of a tag's podcasts, or nil when Qloo won't take the tag.
    def page(tag, offset)
      @counts[:pages] += 1
      Taste::Provider.current.recommend(type: :podcast, filter_tags: [ tag ], popularity_max: POPULARITY_MAX, take: TAKE,
                                        offset: offset.positive? ? offset : nil)
    rescue Taste::BadRequest, Taste::Unsupported, Taste::NotFound => e
      say("skipping #{tag}: #{e.class.name.demodulize}")
      nil
    end

    def consider(entity)
      id = entity.id.to_s
      return if id.empty? || !@seen.add?(id) || Podcast.exists?(qloo_entity_id: id) || Rails.cache.exist?(miss_key(id))

      podcast = QlooMatch.call(entity, source: "qloo_seed", priority: :low, english_only: true,
                                       before_directory_call: method(:pace))
      if podcast&.qloo_entity_id == id
        @linked = linked + 1
        @counts[:matched] += 1
        @counts[:added] += 1 if podcast.source_qloo_seed? && podcast.created_at >= @started_at
        say("#{linked}/#{@target} #{podcast.title}") if (@counts[:matched] % 25).zero?
      else
        @counts[:missed] += 1
        Rails.cache.write(miss_key(id), true, expires_in: MISS_TTL)
      end
    end

    # Podcasts linked to a Qloo entity, counted once and then kept as the run links more.
    def linked = @linked ||= Podcast.where.not(qloo_entity_id: nil).count

    # At most one directory search a second.
    def pace
      if @last_directory_call
        wait = DIRECTORY_INTERVAL - (@clock.call - @last_directory_call)
        @sleeper.call(wait) if wait.positive?
      end
      @last_directory_call = @clock.call
    end

    def miss_key(id) = "catalog:seed:miss:v1:#{id}"

    def say(line) = @log&.call(line)
  end
end
