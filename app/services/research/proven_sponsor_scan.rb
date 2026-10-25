module Research
  # Finds brands that already sponsor podcasts like this one, in two phases:
  #   1. per similar show (one step each): find it in the podcast directory, read its last 20 episodes
  #      (descriptions up to 4,000 characters), and pull sponsor names out with regexes (no LLM, no cost);
  #   2. one step: confirm the most frequent names on Qloo (R93: config/research.yml, 8 by default), keeping only
  #      exact brand matches.
  # Platforms and self-promotion never count (R32): the config/proven_scan.yml denylist and show titles
  # (the user's show and every similar show) everywhere, plus each feed's owner (host or network) and owner
  # email domain within that feed only. Webmail domains (gmail.com, protonmail.com…) are never excluded.
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
    MAX_RESOLUTIONS = Research.caps.fetch(:proven_scan_resolutions)
    LOOKUP_HITS = 3
    EVIDENCE_ITEMS = 3
    MIN_NAME_LENGTH = 2

    Mention = Data.define(:key, :name, :show, :episode)

    # Sponsor names or domains in one piece of text, line by line (a capture never crosses a line break),
    # in order of appearance per pattern, without repeats. Unicode spaces (&nbsp;) count as spaces.
    def self.extract(text)
      text.to_s.split(/\n+/).flat_map do |line|
        line = line.gsub(/[[:space:]]+/, " ")
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
      @denylist ||= Array(config[:denylist]).map { |n| Names.normalize(n) }.to_set
    end

    # Email providers: a host writing from gmail.com says nothing about Gmail sponsoring them.
    def self.webmail_domains
      @webmail_domains ||= Array(config[:webmail_domains]).map { |d| d.to_s.downcase }.to_set
    end

    def self.config = Rails.application.config_for(:proven_scan)

    def self.call(toolkit, podcast_names:, limit:) = new(toolkit, podcast_names: podcast_names, limit: limit).call

    attr_reader :brands

    def initialize(toolkit, podcast_names:, limit:)
      @toolkit = toolkit
      names = Array(podcast_names).map { |n| n.to_s.strip }.reject(&:blank?)
      @names = names.reject { |n| Names.same?(n, toolkit.show.title) }.uniq { |n| Names.normalize(n) }.first(limit.to_i)
      @title_keys = Set.new
      @title_keys.merge(keys_for(toolkit.show.title, *names))
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
          @title_keys.merge(keys_for(info.title, feed.title))
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

    # Records one mention per name per episode and returns the step summary. The feed's own owner and
    # email domain are excluded here, for this feed only.
    def collect(show_title, feed)
      owner_keys = keys_for(feed.owner_name, *email_domain_labels(feed.owner_email))
      found = []
      feed.episodes.each do |episode|
        keys = Set.new
        self.class.extract(episode.description).each do |name|
          key = self.class.key_for(name)
          next if excluded?(name, key) || owner_keys.include?(key) || !keys.add?(key)

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

    # One Qloo lookup per name; a domain is searched without its suffix, a possessive without the "’s". Qloo search is
    # fuzzy (R107), so the lookup takes LOOKUP_HITS and keeps the one with the same name.
    def resolve(name, step)
      base = name.sub(POSSESSIVE, "")
      step.optional("Looking up #{name}") do
        hits = taste.search(query: base.sub(Names::DOMAIN_SUFFIX, ""), types: [ :brand ], take: LOOKUP_HITS)
        hits.find { |hit| Names.same?(hit.name, name) || Names.same?(hit.name, base) }
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

    # Global exclusions: the denylist and every show title seen in this scan.
    def excluded?(name, key) = self.class.denylisted?(name) || @title_keys.include?(key)

    def keys_for(*names)
      names.compact.map { |name| self.class.key_for(name) }.select { |key| key.length >= MIN_NAME_LENGTH }.to_set
    end

    # "host@foundersledger.com" => ["foundersledger"], so "go to foundersledger.com/merch" isn't a sponsor
    # of its own show. Webmail providers and the TLD are skipped: "host@gmail.com" => [].
    def email_domain_labels(email)
      return [] unless email.to_s.include?("@")

      labels = email.to_s.split("@", 2).last.downcase.split(".")[0...-1]
      labels.select { |label| label.length >= 3 && !self.class.webmail_domains.include?(label) }
    end

    # Undated evidence goes last; ties keep scan order.
    def newest_first(items)
      dated, undated = items.partition { |e| Matching::Evidence.published_at(e) }
      dated.sort_by.with_index { |e, i| [ -Matching::Evidence.published_at(e).to_f, i ] } + undated
    end

    def confirm_summary(matched, checked, total)
      scope = checked < total ? "the #{checked} most frequent of #{total} names" : "#{checked} #{'name'.pluralize(checked)}"
      "Matched #{matched.size} of #{scope} on Qloo#{": #{matched.join(', ')}" if matched.any?}"
    end
  end
end
