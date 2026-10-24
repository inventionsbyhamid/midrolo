module Research
  # Finds brands that already sponsor podcasts like this one, in two phases:
  #   1. per similar show (one step each): find it in the podcast directory, read its last 20 episodes
  #      (descriptions up to 4,000 characters), and pull sponsor names out with regexes (no LLM, no cost);
  #   2. one step: confirm the most frequent 15 names on Qloo (R31), keeping only exact brand matches.
  # Platforms and self-promotion never count (R32): the config/proven_scan.yml denylist, plus the user's
  # show and every similar show's title, feed owner (host or network) and owner email domain.
  #
  # Returns {brand_entity_id => {items: [3 latest {show:, episode_title:, published_at: Time}], count: N}}
  # (the Matching::Candidate proven_evidence shape); #brands holds the matched Taste::Entity objects.
  # A show that can't be found or read is skipped with a step warning, and a directory outage ends the
  # scan early with a warning: the scan never fails a run. Qloo auth errors still propagate.
  class ProvenSponsorScan
    PATTERNS = [
      # The lead-in is case-insensitive ("Thanks to our sponsor…" starts sentences); the capture stays
      # case-sensitive (Unicode capitals: "Café Nero", "Trader Joe’s") so it only takes names.
      /(?i:sponsored by|brought to you by|thanks to our sponsors?,?|support for this (?:episode|show) comes from)\s+(\p{Lu}[[:word:]&'’.-]*(?:\s+\p{Lu}[[:word:]&'’.-]*){0,3})/,
      /(?:use|promo) code \w+ (?:at|for) ([\w-]+\.(?:com|co|io|app))/i,
      %r{go to ([\w-]+)\.com/[\w-]+}i
    ].freeze
    # A capture can run into the next sentence ("Notion. Try it free"); cut it at the first sentence break.
    SENTENCE_BREAK = /[.!?,;:](?:\s|\z)/
    POSSESSIVE = /['’]s\z/
    EPISODES = 20
    DESCRIPTION_LIMIT = 4000
    DIRECTORY_RESULTS = 5
    MAX_RESOLUTIONS = 15
    EVIDENCE_ITEMS = 3
    MIN_NAME_LENGTH = 2

    Mention = Data.define(:key, :name, :show, :episode)

    # Sponsor names or domains in one piece of text, line by line (a capture never crosses a line break),
    # in order of appearance per pattern, without repeats.
    def self.extract(text)
      text.to_s.split(/\n+/).flat_map do |line|
        PATTERNS.flat_map { |pattern| line.scan(pattern).map { |(capture)| clean(capture) } }
      end.reject(&:blank?).uniq
    end

    def self.clean(capture)
      capture.to_s.split(SENTENCE_BREAK).first.to_s.sub(/[[:punct:][:space:]]+\z/, "").strip
    end

    # Comparison key: normalized, possessive dropped, so "Notion’s" and "Notion" are one name.
    def self.key_for(name) = Names.normalize(name.to_s.sub(POSSESSIVE, ""))

    # A platform or self-promotion name that never counts as a sponsor (and single letters like "A").
    def self.denylisted?(name)
      key = key_for(name)
      key.length < MIN_NAME_LENGTH || denylist.include?(key)
    end

    def self.denylist
      @denylist ||= Array(Rails.application.config_for(:proven_scan)[:denylist]).map { |n| Names.normalize(n) }.to_set
    end

    def self.call(toolkit, podcast_names:, limit:) = new(toolkit, podcast_names: podcast_names, limit: limit).call

    attr_reader :brands

    def initialize(toolkit, podcast_names:, limit:)
      @toolkit = toolkit
      names = Array(podcast_names).map { |n| n.to_s.strip }.reject(&:blank?)
      @names = names.reject { |n| Names.same?(n, toolkit.show.title) }.uniq { |n| Names.normalize(n) }.first(limit.to_i)
      @own_keys = Set.new
      exclude(toolkit.show.title, toolkit.show.author, *names)
      @mentions = []
      @evidence = {}
      @brands = {}
    end

    def call
      @names.each do |name|
        break if @directory_down

        scan_show(name)
      end
      confirm_on_qloo
      @evidence.transform_values { |items| { items: newest_first(items).first(EVIDENCE_ITEMS), count: items.size } }
    end

    private

    attr_reader :toolkit

    delegate :taste, :log, to: :toolkit, private: true

    # ---- phase 1: read each similar show ----

    def scan_show(name)
      log.step("proven_sponsor_scan", "Checking who sponsors #{name}…", input: name) do |step|
        info = find_in_directory(name, step)
        next unless info

        feed = toolkit.feed_reader.read(info.feed_url, max_episodes: EPISODES, description_limit: DESCRIPTION_LIMIT)
        if feed.episodes.empty?
          step.warn!("Couldn't read #{info.title}'s feed")
        else
          exclude(info.title, feed.title, feed.owner_name, *email_domain_labels(feed.owner_email))
          step.output_summary = collect(info.title, feed)
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

    # Records one mention per name per episode and returns the step summary.
    def collect(show_title, feed)
      found = []
      feed.episodes.each do |episode|
        keys = Set.new
        self.class.extract(episode.description).each do |name|
          key = self.class.key_for(name)
          next if excluded?(name, key) || !keys.add?(key)

          @mentions << Mention.new(key: key, name: name, show: show_title, episode: episode)
          found << name
        end
      end
      return "No sponsor reads in #{feed.episodes.size} episodes" if found.empty?

      "Found #{found.size} sponsor #{'read'.pluralize(found.size)}: #{found.uniq { |n| self.class.key_for(n) }.join(', ')}"
    end

    # ---- phase 2: confirm on Qloo ----

    # The most frequent names first (ties keep first-seen order), at most MAX_RESOLUTIONS lookups.
    def confirm_on_qloo
      ranked = @mentions.reject { |m| excluded?(m.name, m.key) }.group_by(&:key).values
                        .each_with_index.sort_by { |mentions, i| [ -mentions.size, i ] }.map { |mentions, _| mentions }
      return if ranked.empty?

      checked = ranked.first(MAX_RESOLUTIONS)
      log.step("proven_sponsor_scan", "Confirming sponsors on Qloo…", input: checked.map { |ms| ms.first.name }.join(", ")) do |step|
        matched = checked.filter_map do |mentions|
          brand = resolve(mentions.first.name, step)
          mentions.each { |m| record(brand, m) } if brand
          brand&.name
        end
        step.output_summary = confirm_summary(matched.uniq, checked.size, ranked.size)
      end
    end

    # One Qloo lookup per name; a domain is searched without its suffix, a possessive without the "’s".
    def resolve(name, step)
      base = name.sub(POSSESSIVE, "")
      step.optional("Looking up #{name}") do
        hit = taste.search(query: base.sub(Names::DOMAIN_SUFFIX, ""), types: [ :brand ], take: 1).first
        hit if hit && (Names.same?(hit.name, name) || Names.same?(hit.name, base))
      end
    end

    def record(brand, mention)
      toolkit.remember(brand)
      @brands[brand.id] ||= brand
      items = (@evidence[brand.id] ||= [])
      return if items.any? { |e| e[:show] == mention.show && e[:episode_title] == mention.episode.title }

      items << { show: mention.show, episode_title: mention.episode.title, published_at: mention.episode.published_at&.to_time }
    end

    # ---- helpers ----

    def excluded?(name, key) = self.class.denylisted?(name) || @own_keys.include?(key)

    def exclude(*names)
      names.compact.each do |name|
        key = self.class.key_for(name)
        @own_keys << key if key.length >= MIN_NAME_LENGTH
      end
    end

    # "host@foundersledger.com" => ["foundersledger"], so "go to foundersledger.com/merch" isn't a sponsor.
    def email_domain_labels(email)
      labels = email.to_s.split("@", 2).last.to_s.downcase.split(".")
      email.to_s.include?("@") ? labels[0...-1].select { |label| label.length >= 3 } : []
    end

    # Undated evidence goes last; ties keep scan order.
    def newest_first(items)
      dated, undated = items.partition { |e| e[:published_at] }
      dated.sort_by.with_index { |e, i| [ -e[:published_at].to_f, i ] } + undated
    end

    def confirm_summary(matched, checked, total)
      scope = checked < total ? "the #{checked} most frequent of #{total} names" : "#{checked} #{'name'.pluralize(checked)}"
      "Matched #{matched.size} of #{scope} on Qloo#{": #{matched.join(', ')}" if matched.any?}"
    end
  end
end
