module Research
  # Shared state for one research run: the providers, the show's feed, the step log (which also tracks the
  # run's taste-call budget), every taste entity id a tool has returned (for the provenance check on save),
  # and the audience's taste tags (for scoring).
  # No business logic lives here.
  class Toolkit
    FEED_EPISODES = 15

    attr_reader :report, :seen_entity_ids, :log, :feed_reader
    # [Taste::Tag] saved by AudienceProfile; SponsorCandidates counts shared tags against them.
    attr_accessor :audience_tags

    def initialize(report, taste: nil, directory: nil, feed_reader: Podcasts::FeedReader.new,
                   max_taste_calls: StepLogger.configured_max_taste_calls)
      @report = report
      @taste = taste
      @directory = directory
      @feed_reader = feed_reader
      @seen_entity_ids = Set.new
      @log = StepLogger.new(report, max_taste_calls: max_taste_calls)
      @audience_tags = []
    end

    def show = report.show
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

    # Accepts Taste::Entity objects or plain ids.
    def remember(entities)
      Array(entities).each { |e| @seen_entity_ids << (e.respond_to?(:id) ? e.id : e).to_s }
      self
    end
  end
end
