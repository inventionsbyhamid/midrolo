module Research
  # Shared state for one research run: the providers, the show's feed, the step log, every taste entity id
  # a tool has returned (for the provenance check on save), and the audience's taste tags (for scoring).
  # No business logic lives here.
  class Toolkit
    FEED_EPISODES = 15

    attr_reader :report, :seen_entity_ids, :log, :feed_reader
    # [Taste::Tag] saved by AudienceProfile; SponsorCandidates counts shared tags against them.
    attr_accessor :audience_tags

    def initialize(report, taste: nil, directory: nil, feed_reader: Podcasts::FeedReader.new)
      @report = report
      @taste = taste
      @directory = directory
      @feed_reader = feed_reader
      @seen_entity_ids = Set.new
      @log = StepLogger.new(report)
      @audience_tags = []
    end

    def show = report.show
    def taste = @taste ||= Taste::Provider.current
    def directory = @directory ||= Podcasts::Directory.current

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
