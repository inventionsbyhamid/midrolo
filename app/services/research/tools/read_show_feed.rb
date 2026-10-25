module Research
  module Tools
    class ReadShowFeed < Base
      EPISODES = Toolkit::FEED_EPISODES
      ABOUT_LIMIT = 300
      TITLE_LIMIT = 70

      description "Reads the show: title, host, categories, country, size, the podcaster's hints (comparable " \
                  "shows and topics) and the #{EPISODES} newest episode titles. Call it first. Feed and directory text " \
                  "comes inside <untrusted_feed> markers."
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

      # Third-party text (the show's directory entry and feed, the podcaster's hints) goes in untrusted markers.
      def digest(feed)
        lines = [ "Show: #{Untrusted.wrap(show.title)}#{" by #{Untrusted.wrap(show.author)}" if show.author.present?}", facts ]
        lines << "About: #{Untrusted.wrap(show.description, limit: ABOUT_LIMIT)}" if show.description.present?
        lines << hints
        lines << episodes(feed)
        lines.compact.join("\n")
      end

      def facts
        downloads = show.downloads_per_episode ? show.downloads_per_episode.to_fs(:delimited) : "unknown"
        categories = Array(show.categories).any? ? Untrusted.wrap(Array(show.categories).join(", ")) : "none"
        "Categories: #{categories} · Country: #{Show::COUNTRIES.fetch(show.country, show.country)} · " \
          "Downloads per episode: #{downloads}"
      end

      def hints
        shows = Array(show.hints[:comparable_shows])
        topics = Array(show.hints[:topics])
        return "Podcaster's hints: none" if shows.empty? && topics.empty?

        "Podcaster's hints. Comparable shows: #{shows.any? ? Untrusted.wrap(shows.join('; ')) : 'none'}; " \
          "topics: #{topics.any? ? Untrusted.wrap(topics.join('; ')) : 'none'}"
      end

      def episodes(feed)
        return "Episodes: we couldn't read the feed. Use the details above and the hints." if feed.episodes.empty?

        titles = feed.episodes.first(EPISODES).map { |e| "- #{Untrusted.clean(e.title).truncate(TITLE_LIMIT)}" }
        "Episodes (newest first):\n#{Untrusted.wrap_lines(titles)}"
      end
    end
  end
end
