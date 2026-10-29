module Sponsors
  # Who the show itself is, so its own plugs never read as sponsors: its title, author (often the network) and hosts,
  # and its own domains (website, feed host, owner email, the pages its episodes link to). Also the words a vanity path
  # is made of ("squarespace.com/tim" on The Tim Ferriss Show).
  class Context
    MIN_KEY = 4
    MIN_TOKEN = 3
    # An episode link host this share of episodes point at is the show's own site.
    OWN_LINK_SHARE = 0.5

    attr_reader :title, :keys, :tokens, :domains

    def self.for(podcast, episodes: [])
      people = podcast.persisted? ? podcast.people.pluck(:name) : []
      new(title: podcast.title, author: podcast.author, people: people,
          urls: [ podcast.website, podcast.feed_url ], email: podcast.owner_email,
          episode_links: episodes.map(&:link))
    end

    def initialize(title:, author: nil, people: [], urls: [], email: nil, episode_links: [])
      @title = title.to_s
      names = [ title, author, *people ].compact_blank
      @keys = names.map { |name| Research::Names.normalize(name) }.select { |key| key.length >= MIN_KEY }.to_set
      @tokens = names.flat_map { |name| words(name) }.to_set
      @domains = (urls.filter_map { |url| Brand.normalize_domain(url) } + email_domain(email) + link_domains(episode_links)).to_set
    end

    # The show's own name, its author's or a host's ("The Tim Ferriss Show", "Tim Ferriss", "Wondery").
    def own_name?(name)
      key = Research::ProvenSponsorScan.key_for(name)
      return false if key.length < 2

      @keys.include?(key) || (key.length >= MIN_KEY && @keys.any? { |own| own.include?(key) || key.include?(own) })
    end

    # One of the show's own domains, or one named after the show or its host ("darknetdiaries.com").
    def own_domain?(domain)
      return false if domain.blank?

      @domains.include?(domain) || own_name?(domain_label(domain))
    end

    # A path like "/tim", "/lex50" or "/darknet": a vanity URL made for this show's listeners.
    def vanity_slug?(slug)
      letters = slug.to_s.downcase.gsub(/[^a-z]/, "")
      return false if letters.length < MIN_TOKEN || slug.to_s.length > 30

      @tokens.include?(letters) || @keys.include?(letters)
    end

    def domain_label(domain) = domain.to_s.split(".").first.to_s

    private

    def words(name)
      name.to_s.downcase.scan(/[a-z]+/).select { |word| word.length >= MIN_TOKEN && !Rules.generic_word?(word) }
    end

    def email_domain(email)
      domain = Brand.normalize_domain(email.to_s.split("@", 2).last) if email.to_s.include?("@")
      domain && !Brand.webmail?(domain) ? [ domain ] : []
    end

    # The host most episode links point at (the show's site), unless it's a platform (an Apple or Spotify page).
    def link_domains(links)
      hosts = links.filter_map { |link| Brand.normalize_domain(link) if link.present? }
      return [] if hosts.empty?

      host, count = hosts.tally.max_by { |_, n| n }
      count >= hosts.size * OWN_LINK_SHARE && !Rules.platform_domain?(host) ? [ host ] : []
    end
  end
end
