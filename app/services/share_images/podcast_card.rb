module ShareImages
  # A catalog podcast's share image (its page at /podcasts/:slug), or one of its episodes': the stored artwork, the
  # title, host and first category, then one number with where it came from (a fresh verified or provided reading from
  # the stats lane, labelled as the page labels it, else the episode count from the feed), and the marks "Stats
  # verified" and "Open to sponsors". Never Qloo data, and never a number without its source. An episode's card has the
  # episode's title, the show and host under it, and its date and length.
  #
  # Everything shown goes into the cache key (with the podcast's updated_at and the stored artwork's key), so any change
  # draws it again and the og:image URL (?v=) changes with it. Building the key reads only what the page preloads
  # (artwork, readings, listing), or one query for the readings on an episode page.
  class PodcastCard < Card
    # Numbers this size and up are shortened ("2.1K").
    COMPACT_FROM = 1_000

    def initialize(podcast, episode: nil)
      @podcast = podcast
      @episode = episode
    end

    def draw
      picture = StoredArtwork.read(@podcast, size: Layout::ARTWORK[:size])
      png = Renderer.png(layout(artwork: picture ? :image : :fallback).svg, artwork: picture,
                         at: Layout::ARTWORK.values_at(:x, :y))
      # Stored artwork that couldn't be read yet (its variant still being made, say) is worth drawing again soon.
      Image.new(png: png, complete: picture.present? || !StoredArtwork.stored?(@podcast))
    end

    def artwork? = true

    # The alt text for the og:image.
    def alt
      return "#{@episode.title}, an episode of #{@podcast.title}, on #{APP_NAME}" if @episode

      "#{@podcast.title} podcast on #{APP_NAME}"
    end

    private

    def key_parts
      [ (@episode ? "episode" : "podcast"), @podcast.cache_key_with_version, @episode&.cache_key_with_version,
        StoredArtwork.state(@podcast), Digest::SHA256.hexdigest(fields.to_json).first(16) ].compact
    end

    def fields
      @fields ||= @episode ? episode_fields : podcast_fields
    end

    def podcast_fields
      value, label, note = key_number
      { label: "Podcast", title: @podcast.title, subline: byline, stat: ([ value, label ] if value), note: note,
        marks: marks, seed: @podcast.public_id }
    end

    def episode_fields
      host = ", hosted by #{@podcast.author}" if @podcast.author.present?
      { label: "Episode", title: @episode.title.presence || "An episode of #{@podcast.title}", subline: "#{@podcast.title}#{host}",
        note: episode_note, marks: marks, seed: @podcast.public_id }
    end

    # "Hosted by Jack Rhysider · Technology"
    def byline
      [ ("Hosted by #{@podcast.author}" if @podcast.author.present?), @podcast.categories.first.presence ].compact.join(" · ").presence
    end

    def episode_note
      seconds = @episode.duration_seconds.to_i
      length = "#{seconds / 60} min" if seconds >= 60
      [ @episode.published_at&.strftime("%b %-d, %Y"), length ].compact.join(" · ").presence
    end

    def marks
      [ ([ "Stats verified", :success ] if numbers&.verified?),
        ([ "Open to sponsors", :accent ] if @podcast.open_to_sponsors?) ].compact
    end

    # [value, label, source] for the one number the card shows, or nil.
    def key_number
      reading = shown_reading
      return feed_number unless reading

      value = numbers.bands? ? helpers.stats_band(reading.value) : compact(reading.value)
      source = if reading.trust_verified?
        "Verified with #{helpers.stats_source_name(reading)} · #{helpers.stats_date(reading.captured_at)}"
      else
        "Provided by the show · #{helpers.stats_date(reading.captured_at)}"
      end
      [ value, helpers.stats_metric_label(reading), source ]
    end

    # The per-episode figure while it's fresh and verified or provided, else a platform's 30-day listeners (or its
    # first number shown), else nothing. Only for a claimed show: before a claim the page shows feed facts only.
    def shown_reading
      return nil unless numbers

      per_episode = numbers.per_episode
      return per_episode if per_episode && !per_episode.expired? && (per_episode.trust_verified? || per_episode.trust_provided?)

      group = numbers.groups.reject(&:expired?).first
      group && (group.readings.find { |reading| reading.metric == "listeners_30d" } || group.readings.first)
    end

    def feed_number
      count = @podcast.episode_count.to_i
      [ ActiveSupport::NumberHelper.number_to_delimited(count), count == 1 ? "episode" : "episodes", "From the show's RSS feed" ] if count.positive?
    end

    def numbers
      return @numbers if defined?(@numbers)

      @numbers = (::Stats::PageNumbers.new(@podcast) if @podcast.claimed?)
    end

    def compact(value)
      return ActiveSupport::NumberHelper.number_to_delimited(value) if value < COMPACT_FROM

      ActiveSupport::NumberHelper.number_to_human(value, format: "%n%u", precision: 1, significant: false,
                                                         units: { thousand: "K", million: "M", billion: "B" })
    end

    def helpers = ApplicationController.helpers
  end
end
