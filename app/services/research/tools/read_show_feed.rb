module Research
  module Tools
    class ReadShowFeed < Base
      EPISODES = Toolkit::FEED_EPISODES
      ABOUT_LIMIT = 300
      TITLE_LIMIT = 70

      description "Reads the show: title, host, categories, country, size, the podcaster's hints (comparable " \
                  "shows and topics) and the #{EPISODES} newest episode titles. Call it first."
      arguments

      def execute
        log.step("read_show_feed", "Reading your last #{EPISODES} episodes…", input: show.title) do |step|
          feed = toolkit.feed
          if feed.episodes.empty?
            step.warn!("Couldn't read the feed, so we used the directory details")
          else
            step.output_summary = "Read #{feed.episodes.size} episodes"
          end
          digest(feed)
        end
      end

      private

      def digest(feed)
        lines = [ "Show: #{show.title}#{" by #{show.author}" if show.author.present?}", facts ]
        lines << "About: #{show.description.to_s.squish.truncate(ABOUT_LIMIT)}" if show.description.present?
        lines << hints
        lines << episodes(feed)
        lines.compact.join("\n")
      end

      def facts
        downloads = show.downloads_per_episode ? show.downloads_per_episode.to_fs(:delimited) : "unknown"
        "Categories: #{Array(show.categories).join(', ').presence || 'none'} · Country: #{Show::COUNTRIES.fetch(show.country, show.country)} · " \
          "Downloads per episode: #{downloads}"
      end

      def hints
        shows = Array(show.hints[:comparable_shows])
        topics = Array(show.hints[:topics])
        return "Podcaster's hints: none" if shows.empty? && topics.empty?

        "Podcaster's hints — comparable shows: #{shows.join('; ').presence || 'none'}; topics: #{topics.join('; ').presence || 'none'}"
      end

      def episodes(feed)
        return "Episodes: we couldn't read the feed. Use the details above and the hints." if feed.episodes.empty?

        [ "Episodes (newest first):", *feed.episodes.first(EPISODES).map { |e| "- #{e.title.to_s.squish.truncate(TITLE_LIMIT)}" } ].join("\n")
      end
    end
  end
end
