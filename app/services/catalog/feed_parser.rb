module Catalog
  # Reads a podcast's RSS feed (bytes Catalog::FeedFetcher fetched, already under its cap) into plain values: the
  # channel's facts, the newest 50 episodes and the people the feed names, with the itunes and podcast namespace tags
  # (guid, person, transcript, txt, locked, block, medium, image, funding). Every text is plain (Catalog::PlainText),
  # every link http(s) through Show.http_url, every number bounded. Raises Unreadable for anything that isn't an RSS
  # feed with a channel.
  #
  # Nokogiri reads the XML directly rather than through Feedjira, since Feedjira's entries can't carry the podcast
  # namespace tags and matching two parses item by item would be fragile. Tags are matched by name and namespace URI,
  # case-insensitively, and an undeclared "itunes:" or "podcast:" prefix still counts.
  class FeedParser
    class Unreadable < StandardError; end

    MAX_EPISODES = 50
    TITLE_LIMIT = 300
    NAME_LIMIT = 120
    TEXT_LIMIT = Podcast::DESCRIPTION_LIMIT
    URL_LIMIT = 2000
    MAX_CATEGORIES = 10
    MAX_TXT = 10
    MAX_FUNDING = 5
    MAX_PEOPLE = 50
    # Hosting and measurement are read off this many of the newest episodes, so an old prefix doesn't linger.
    DETECTION_EPISODES = 10
    NAMESPACES = { itunes: %r{itunes\.com/dtds/podcast}i, podcast: /podcastindex|podcast-namespace/i,
                   content: %r{purl\.org/rss/1\.0/modules/content}i }.freeze
    PERSON_ROLES = { "host" => "host", "co-host" => "host", "cohost" => "host", "guest" => "guest" }.freeze
    # podcast:transcript types, best first: the text the sponsor scan and pages can read most easily.
    TRANSCRIPT_TYPES = %w[text/vtt application/x-subrip application/srt text/srt application/json text/html text/plain].freeze
    EARLIEST = Time.utc(1990, 1, 1)

    Person = Data.define(:name, :role, :href, :img_url)
    Funding = Data.define(:url, :text)
    Episode = Data.define(:guid, :title, :description, :published_at, :duration_seconds, :episode_type, :season, :number,
                          :enclosure_url, :link, :transcript_url, :people)
    Result = Data.define(:title, :author, :description, :language, :explicit, :itunes_type, :categories, :website,
                         :artwork_url, :owner_email, :podcast_guid, :new_feed_url, :blocked, :locked, :medium, :txt,
                         :funding, :people, :episodes, :episode_count, :first_published_at, :last_published_at,
                         :cadence_days, :hosting_provider, :measurement)

    def self.call(xml, feed_url: nil, now: Time.current) = new(xml, feed_url, now).call

    def initialize(xml, feed_url, now)
      @xml = xml.to_s
      @feed_url = feed_url
      @now = now
    end

    def call
      channel = channel_of(parse_document)
      items = children(channel, "item")
      dated = items.each_with_index.map { |item, index| [ item, published_at(item), index ] }
      newest = dated.sort_by { |_, at, index| [ at ? 0 : 1, -at.to_i, index ] }.first(MAX_EPISODES)
      episodes = dedupe(newest.map { |item, at, _| episode(item, at) })
      dates = dated.filter_map { |_, at, _| at }
      result(channel, episodes, items.size, dates)
    end

    private

    def parse_document
      raise Unreadable, "feed_empty" if @xml.strip.empty?

      Nokogiri::XML(to_utf8(@xml), nil, "UTF-8", Nokogiri::XML::ParseOptions.new.recover.nonet)
    rescue Nokogiri::XML::SyntaxError
      raise Unreadable, "feed_unparseable"
    end

    def channel_of(doc)
      root = doc.root
      raise Unreadable, "feed_unparseable" unless root&.name == "rss"

      children(root, "channel").first || raise(Unreadable, "feed_unparseable")
    end

    def result(channel, episodes, count, dates)
      enclosures = episodes.first(DETECTION_EPISODES).map(&:enclosure_url)
      Result.new(
        title: line(text(channel, "title")) || line(text(channel, "title", :itunes)),
        author: line(text(channel, "author", :itunes)) || line(owner_name(channel)),
        description: plain(text(channel, "description") || text(channel, "summary", :itunes) ||
                           text(channel, "subtitle", :itunes)),
        language: language(text(channel, "language")),
        explicit: %w[yes true explicit].include?(text(channel, "explicit", :itunes).to_s.downcase),
        itunes_type: text(channel, "type", :itunes).to_s.downcase.presence_in(%w[episodic serial]),
        categories: categories(channel), website: url(text(channel, "link")), artwork_url: artwork(channel),
        owner_email: owner_email(channel), podcast_guid: podcast_guid(channel),
        new_feed_url: url(text(channel, "new-feed-url", :itunes)), blocked: blocked?(channel),
        locked: text(channel, "locked", :podcast).to_s.casecmp?("yes"),
        medium: text(channel, "medium", :podcast).to_s.downcase.first(20).presence,
        txt: children(channel, "txt", :podcast).filter_map { |node| line(node.text, 500) }.first(MAX_TXT),
        funding: funding(channel), people: people(channel), episodes: episodes, episode_count: count,
        first_published_at: dates.min, last_published_at: dates.select { |at| at <= @now + 1.day }.max,
        cadence_days: cadence(episodes), hosting_provider: Detection.hosting_provider(enclosures, feed_url: @feed_url),
        measurement: Detection.measurement(enclosures)
      )
    end

    def episode(item, published_at)
      enclosure = children(item, "enclosure").first
      Episode.new(
        guid: guid(item, enclosure), title: line(text(item, "title")) || line(text(item, "title", :itunes)) || "Untitled episode",
        description: plain(text(item, "encoded", :content) || text(item, "description") || text(item, "summary", :itunes)),
        published_at: published_at, duration_seconds: duration(text(item, "duration", :itunes)),
        episode_type: text(item, "episodeType", :itunes).to_s.downcase.presence_in(%w[full trailer bonus]),
        season: whole(text(item, "season", :itunes) || text(item, "season", :podcast)),
        number: whole(text(item, "episode", :itunes) || text(item, "episode", :podcast)),
        enclosure_url: url(enclosure&.[]("url")), link: url(text(item, "link")), transcript_url: transcript(item),
        people: people(item)
      )
    end

    # A feed that repeats a guid keeps its first (newest) episode under it: one row per guid.
    def dedupe(episodes) = episodes.uniq(&:guid)

    # The item's guid; else its enclosure URL, link, or a digest of its title and date. A guid too long to index
    # becomes its digest.
    def guid(item, enclosure)
      value = text(item, "guid") || enclosure&.[]("url").to_s.strip.presence || text(item, "link") ||
              "title:#{text(item, 'title')}|#{text(item, 'pubDate')}"
      value = value.gsub(PlainText::CONTROL, "")
      value.length > 255 ? "sha256:#{Digest::SHA256.hexdigest(value)}" : value
    end

    def published_at(item)
      raw = text(item, "pubDate")
      return nil unless raw

      time = (Time.rfc2822(raw) rescue nil) || (Time.zone.parse(raw) rescue nil)
      time.utc if time && time >= EARLIEST && time <= @now + 1.year
    end

    # "1:02:03", "62:03", "3723" or "3723.5" seconds; nil for anything else or over 100 hours.
    def duration(raw)
      parts = raw.to_s.strip.split(":")
      return nil if parts.empty? || parts.size > 3 || parts.any? { |part| !part.match?(/\A\d{1,6}(?:\.\d+)?\z/) }

      seconds = parts.map(&:to_f).reduce(0) { |total, part| total * 60 + part }.floor
      seconds if seconds.between?(1, 100 * 3600)
    end

    def whole(raw)
      number = raw.to_s.strip[/\A\d{1,7}/]&.to_i
      number if number&.between?(0, 1_000_000)
    end

    def transcript(item)
      nodes = children(item, "transcript", :podcast).select { |node| url(node["url"]) }
      best = nodes.min_by { |node| TRANSCRIPT_TYPES.index(node["type"].to_s.downcase) || TRANSCRIPT_TYPES.size }
      url(best&.[]("url"))
    end

    def people(node)
      children(node, "person", :podcast).first(MAX_PEOPLE).filter_map do |person|
        name = line(person.text, NAME_LIMIT)
        next unless name

        Person.new(name: name, role: PERSON_ROLES.fetch(person["role"].to_s.strip.downcase.presence || "host", "other"),
                   href: url(person["href"]), img_url: url(person["img"]))
      end
    end

    def categories(channel)
      children(channel, "category", :itunes).flat_map do |category|
        [ category, *children(category, "category", :itunes) ].map { |node| line(node["text"], 100) }
      end.compact.uniq.first(MAX_CATEGORIES)
    end

    def artwork(channel)
      itunes = children(channel, "image", :itunes).first&.[]("href")
      image = children(channel, "image").first
      podcast = children(channel, "image", :podcast).first&.[]("href")
      url(itunes) || url(image && text(image, "url")) || url(podcast)
    end

    # The owner's address as Shows::OwnerEmail reads it: itunes:owner's email, then an email tag, then managingEditor.
    def owner_email(channel)
      owner = children(channel, "owner", :itunes).first
      candidates = [ owner && text(owner, "email", :itunes), any_namespace_text(channel, "email"), text(channel, "managingEditor") ]
      candidates.filter_map { |value| value.to_s[Shows::OwnerEmail::EMAIL] }.first&.first(254)
    end

    def owner_name(channel)
      owner = children(channel, "owner", :itunes).first
      owner && text(owner, "name", :itunes)
    end

    def podcast_guid(channel)
      value = text(channel, "guid", :podcast).to_s.strip
      value if value.match?(/\A[\w-]{8,64}\z/)
    end

    # itunes:block yes, or a podcast:block yes that names no single platform: the show asks not to be listed.
    def blocked?(channel)
      return true if text(channel, "block", :itunes).to_s.casecmp?("yes")

      children(channel, "block", :podcast).any? { |node| node.text.strip.casecmp?("yes") && node["id"].blank? }
    end

    def funding(channel)
      children(channel, "funding", :podcast).filter_map do |node|
        link = url(node["url"])
        Funding.new(url: link, text: line(node.text, 128)) if link
      end.first(MAX_FUNDING)
    end

    def language(raw)
      code = raw.to_s.strip.downcase.tr("_", "-")
      code if code.match?(/\A[a-z]{2,3}(?:-[a-z0-9]{2,8}){0,2}\z/)
    end

    # The median gap between the parsed episodes, in whole days (1 at least), or nil with fewer than two dates.
    def cadence(episodes)
      gaps = episodes.filter_map(&:published_at).sort.reverse.each_cons(2).map { |a, b| (a - b) / 1.day }
      return nil if gaps.empty?

      sorted = gaps.sort
      mid = sorted.size / 2
      median = sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
      [ median.round, 1 ].max
    end

    # ---- XML ----

    # The element children of node called name in namespace ns (:itunes, :podcast, :content), or with ns nil in no
    # namespace or a default one (an old feed's <rss xmlns="http://backend.userland.com/rss2">), never a prefixed one
    # (atom:link isn't the channel's link).
    def children(node, name, ns = nil)
      prefixed = "#{ns}:#{name}" if ns
      node.element_children.select do |child|
        if child.name == name
          namespace = child.namespace
          ns ? namespace&.href.to_s.match?(NAMESPACES.fetch(ns)) : namespace.nil? || namespace.prefix.nil?
        else
          prefixed && child.namespace.nil? && child.name.casecmp?(prefixed)
        end
      end
    end

    def text(node, name, ns = nil) = children(node, name, ns).first&.text&.strip.presence

    def any_namespace_text(node, name) = node.element_children.find { |child| child.name == name }&.text&.strip.presence

    def line(value, limit = TITLE_LIMIT) = PlainText.line(value, limit: limit)

    def plain(value) = PlainText.call(value, limit: TEXT_LIMIT)

    def url(value)
      link = Show.http_url(value.to_s.gsub(/[[:space:]]/, ""))
      link if link && link.length <= URL_LIMIT
    end

    # The bytes as UTF-8: the declared encoding when it isn't UTF-8, else UTF-8, else Windows-1252 (a common mislabel).
    def to_utf8(bytes)
      raw = bytes.b.sub(/\A\xEF\xBB\xBF/n, "")
      declared = raw[/\A\s*<\?xml[^>]*encoding=["']([\w.-]+)["']/in, 1]
      encoding = (Encoding.find(declared) if declared) rescue nil
      if encoding && encoding != Encoding::UTF_8 && encoding.ascii_compatible?
        text = raw.dup.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        return text.sub(/(\A\s*<\?xml[^>]*encoding=["'])[\w.-]+/i, '\1UTF-8')
      end

      text = raw.dup.force_encoding(Encoding::UTF_8)
      return text if text.valid_encoding?

      raw.dup.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end
  end
end
