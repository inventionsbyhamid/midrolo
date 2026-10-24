module Research
  # Finds brands that already sponsor podcasts like this one. For each similar show it finds the feed in
  # the podcast directory, reads the last 20 episodes, pulls sponsor names out of the descriptions with
  # regexes (no LLM, so it costs nothing), and keeps only names that resolve to a Qloo brand exactly.
  #
  # Returns {brand_entity_id => [{show:, episode_title:, published_at: Time}]}; #brands holds the matched
  # Taste::Entity objects. A show that can't be found or read is skipped with a step warning, and a
  # directory outage ends the scan early with a warning: the scan never fails a run. Qloo auth errors
  # still propagate.
  class ProvenSponsorScan
    PATTERNS = [
      # The lead-in is case-insensitive ("Thanks to our sponsor…" starts sentences); the capture stays
      # case-sensitive so it only takes capitalised names.
      /(?i:sponsored by|brought to you by|thanks to our sponsors?,?|support for this (?:episode|show) comes from)\s+([A-Z][\w&'.-]*(?:\s+[A-Z][\w&'.-]*){0,3})/,
      /(?:use|promo) code \w+ (?:at|for) ([\w-]+\.(?:com|co|io|app))/i,
      %r{go to ([\w-]+)\.com/[\w-]+}i
    ].freeze
    # A capture can run into the next sentence ("Notion. Try it free"); cut it at the first sentence break.
    SENTENCE_BREAK = /[.!?,;:](?:\s|\z)/
    EPISODES = 20
    DIRECTORY_RESULTS = 5

    # Sponsor names or domains in one piece of text, in order of appearance per pattern, without repeats.
    def self.extract(text)
      PATTERNS.flat_map { |pattern| text.to_s.scan(pattern).map { |(capture)| clean(capture) } }.reject(&:blank?).uniq
    end

    def self.clean(capture)
      capture.to_s.split(SENTENCE_BREAK).first.to_s.sub(/['’]s\z/, "").sub(/[[:punct:][:space:]]+\z/, "").strip
    end

    def self.call(toolkit, podcast_names:, limit:) = new(toolkit, podcast_names: podcast_names, limit: limit).call

    attr_reader :brands

    def initialize(toolkit, podcast_names:, limit:)
      @toolkit = toolkit
      own_title = toolkit.show.title
      @names = Array(podcast_names).map { |n| n.to_s.strip }.reject(&:blank?)
                                   .reject { |n| Names.same?(n, own_title) }
                                   .uniq { |n| Names.normalize(n) }.first(limit.to_i)
      @resolved = {}
      @evidence = {}
      @brands = {}
    end

    def call
      @names.each do |name|
        break if @directory_down

        scan_show(name)
      end
      @evidence.transform_values { |list| newest_first(list) }
    end

    private

    attr_reader :toolkit

    delegate :taste, :log, to: :toolkit, private: true

    def scan_show(name)
      log.step("proven_sponsor_scan", "Checking who sponsors #{name}…", input: name) do |step|
        info = find_in_directory(name, step)
        next unless info

        feed = toolkit.feed_reader.read(info.feed_url, max_episodes: EPISODES)
        if feed.episodes.empty?
          step.warn!("Couldn't read #{info.title}'s feed")
        else
          scan_feed(info.title, feed, step)
        end
      end
    end

    def find_in_directory(name, step)
      info = toolkit.directory.search(name, limit: DIRECTORY_RESULTS)
                    .find { |show| show.feed_url.present? && Names.close?(name, show.title) }
      step.warn!("Couldn't find #{name} in the podcast directory") unless info
      info
    rescue Podcasts::Directory::Unavailable
      @directory_down = true
      step.warn!("Podcast directory unavailable, so the rest of the scan was skipped")
      nil
    end

    def scan_feed(show_title, feed, step)
      mentions = 0
      found = {}
      feed.episodes.each do |episode|
        self.class.extract(episode.description).each do |candidate|
          mentions += 1
          brand = resolve(candidate, step)
          next unless brand

          record(brand, show_title, episode)
          found[brand.id] = brand.name
        end
      end
      step.output_summary = summary(found.values, mentions, feed.episodes.size)
    end

    # One Qloo lookup per distinct candidate per scan; an outage skips just that candidate.
    def resolve(candidate, step)
      key = Names.normalize(candidate)
      return nil if key.empty?
      return @resolved[key] if @resolved.key?(key)

      @resolved[key] = step.optional("Looking up #{candidate}") do
        hit = taste.search(query: candidate.sub(Names::DOMAIN_SUFFIX, ""), types: [ :brand ], take: 1).first
        hit if hit && Names.same?(hit.name, candidate)
      end
    end

    def record(brand, show_title, episode)
      toolkit.remember(brand)
      @brands[brand.id] ||= brand
      list = (@evidence[brand.id] ||= [])
      return if list.any? { |e| e[:show] == show_title && e[:episode_title] == episode.title }

      list << { show: show_title, episode_title: episode.title, published_at: episode.published_at&.to_time }
    end

    # Undated evidence goes last; ties keep scan order.
    def newest_first(list)
      dated, undated = list.partition { |e| e[:published_at] }
      dated.sort_by.with_index { |e, i| [ -e[:published_at].to_f, i ] } + undated
    end

    def summary(names, mentions, episodes)
      return "No sponsor reads in #{episodes} episodes" if mentions.zero?
      return "#{mentions} sponsor #{'mention'.pluralize(mentions)}, none matched on Qloo" if names.empty?

      "Found #{names.size} #{'sponsor'.pluralize(names.size)} on Qloo: #{names.join(', ')}"
    end
  end
end
