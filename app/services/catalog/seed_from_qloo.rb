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
  # The tags are read round robin (each tag's page at one offset, then the next offset), so every genre gets in early.
  # A Cursor says where that stands; call reads every page in one go (catalog:seed), read_page reads one and returns the
  # cursor after it (Catalog::SeedStepJob, the paced seed, which spreads the pages over hours).
  #
  #   Catalog::SeedFromQloo.call(target: 1000, log: ->(line) { puts line })
  #   step = Catalog::SeedFromQloo.read_page(Catalog::SeedFromQloo::Cursor.start(TAGS.size), target: 1000)
  #   step.cursor # where the next page is; step.stopped is nil while there is one
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
    # One page's outcome: the cursor after it, why the seed stops (nil while pages remain), the tag read, the podcasts
    # linked to Qloo in all, and this page's matched (added of them new) and missed entities.
    Step = Data.define(:cursor, :stopped, :tag, :linked, :matched, :added, :missed)

    # Where a seed stands: the tag it reads next (an index into the tags, nil once every tag ran out), the offset this
    # round reads every tag at, and the indexes of the tags that ran out. Plain values, so a job can carry it.
    Cursor = Data.define(:tag_index, :offset, :exhausted) do
      def self.start(tag_count) = new(tag_index: (0 if tag_count.positive?), offset: 0, exhausted: [])

      def self.from_h(hash)
        hash = hash.to_h.stringify_keys
        new(tag_index: hash["tag_index"]&.to_i, offset: hash["offset"].to_i, exhausted: Array(hash["exhausted"]).map(&:to_i))
      end

      def finished? = tag_index.nil?

      # The cursor after this one's page: the next tag still going at this offset, else the first one at the next
      # offset. ran_out drops this tag.
      def advance(tag_count, ran_out:)
        gone = ran_out ? (exhausted | [ tag_index ]).sort : exhausted
        later = ((tag_index + 1)...tag_count).find { |index| gone.exclude?(index) }
        return with(tag_index: later, exhausted: gone) if later

        with(tag_index: (0...tag_count).find { |index| gone.exclude?(index) }, offset: offset + TAKE, exhausted: gone)
      end

      def to_h = { "tag_index" => tag_index, "offset" => offset, "exhausted" => exhausted }
    end

    def self.call(target: DEFAULT_TARGET, tags: TAGS, log: nil, sleeper: ->(seconds) { sleep(seconds) },
                  clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      new(target:, tags:, log:, sleeper:, clock:).call
    end

    # Reads the one page at cursor and matches its podcasts (the paced seed). Returns a Step.
    def self.read_page(cursor, target: DEFAULT_TARGET, tags: TAGS, log: nil, sleeper: ->(seconds) { sleep(seconds) },
                       clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      new(target:, tags:, log:, sleeper:, clock:).read_page(cursor)
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

    def read_page(cursor)
      following, stopped = Taste::CallGuard.waiting { page_step(cursor) }
      Step.new(cursor: following, stopped: stopped, tag: (@tags[cursor.tag_index] unless cursor.finished?), linked: linked,
               matched: @counts[:matched], added: @counts[:added], missed: @counts[:missed])
    end

    private

    # Why it stopped: "target", "exhausted", or the Qloo problem that ended it.
    def seed
      cursor = Cursor.start(@tags.size)
      loop do
        cursor, stopped = page_step(cursor)
        return stopped if stopped
      end
    end

    # The page at cursor, its podcasts matched: [the cursor after it, why the seed stops or nil]. A Qloo problem keeps
    # the cursor where it was, so a later run reads that page.
    def page_step(cursor)
      return [ cursor, "target" ] if linked >= @target
      return [ cursor, "exhausted" ] if cursor.finished?

      entities = page(@tags[cursor.tag_index], cursor.offset)
      ran_out = entities.nil? || entities.size < TAKE || cursor.offset + TAKE >= MAX_OFFSET
      following = cursor.advance(@tags.size, ran_out: ran_out)
      entities&.each do |entity|
        consider(entity)
        return [ following, "target" ] if linked >= @target
      end
      [ following, ("exhausted" if following.finished?) ]
    rescue Taste::CallCapReached, Taste::RateLimited => e
      say("stopped: #{e.message}")
      [ cursor, "qloo_limit" ]
    rescue Taste::AuthError, Taste::MissingCredentials, Taste::Unavailable => e
      say("stopped: #{e.class.name.demodulize}: #{e.message}")
      [ cursor, "qloo_error" ]
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
