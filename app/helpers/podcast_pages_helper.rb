# The public catalog's pages (lane L3; every helper starts with pages_): other lanes' slots with a fallback, dates and
# rhythm in words, search titles and descriptions, and the structured data (JSON-LD) search engines read.
module PodcastPagesHelper
  LANGUAGES = { "en" => "English", "es" => "Spanish", "de" => "German", "fr" => "French", "pt" => "Portuguese",
                "it" => "Italian", "nl" => "Dutch", "sv" => "Swedish", "no" => "Norwegian", "da" => "Danish",
                "fi" => "Finnish", "pl" => "Polish", "ja" => "Japanese", "zh" => "Chinese", "ko" => "Korean",
                "hi" => "Hindi", "ar" => "Arabic", "tr" => "Turkish", "ru" => "Russian", "id" => "Indonesian" }.freeze
  # Measurement prefixes as people know them (config/measurement_prefixes.yml keys).
  MEASUREMENT_NAMES = { "op3" => "OP3", "podtrac" => "Podtrac", "chartable" => "Chartable", "podscribe" => "Podscribe",
                        "magellan" => "Magellan AI", "spotify" => "Spotify Ad Analytics" }.freeze
  DESCRIPTION_LIMIT = 158
  # Where a podcast page's downloads figure came from, for its structured data.
  VERIFIED_PLAYS = "Spotify and Apple plays per episode over the last 30 days, read from the platforms by #{APP_NAME}".freeze
  PROVIDED_DOWNLOADS = "Downloads per episode, provided by the show".freeze
  JSON_LD_DESCRIPTION_LIMIT = 500
  # The About section folds a long description behind "Read more" past this.
  ABOUT_FOLD = 600

  # Another lane's partial (podcasts/_numbers and the rest), or the block's fallback when it renders nothing yet.
  def pages_slot(partial, **locals, &fallback)
    html = render(partial, **locals)
    # Development wraps every partial in <!-- BEGIN ... --> comments; an empty partial is still empty.
    return html if html.to_s.gsub(/<!--.*?-->/m, "").strip.present?

    fallback ? capture(&fallback) : nil
  end

  # A partial another lane adds (brands/_sponsored_shows), rendered once it exists, else the fallback.
  def pages_optional_slot(partial, **locals, &fallback)
    prefix, name = partial.split("/", 2)
    return pages_slot(partial, **locals, &fallback) if lookup_context.exists?(name, [ prefix ], true)

    fallback ? capture(&fallback) : nil
  end

  # "just now", "3h ago", "9 days ago", "4 months ago": when a feed was checked or an episode came out.
  def pages_ago(time)
    return nil unless time

    seconds = (Time.current - time).to_i
    if seconds < 90 then "just now"
    elsif seconds < 1.hour then "#{seconds / 60} min ago"
    elsif seconds < 1.day then "#{seconds / 3600}h ago"
    elsif seconds < 60.days then "#{pluralize(seconds / 1.day, 'day')} ago"
    elsif seconds < 2.years then "#{pluralize(seconds / 30.days, 'month')} ago"
    else "#{pluralize(seconds / 365.days, 'year')} ago"
    end
  end

  # How often episodes come out, from the feed's median gap: "Daily", "Weekly", "Every 2 weeks", "Every 10 days".
  def pages_cadence(podcast)
    days = podcast.cadence_days.to_i
    return nil unless days.positive?

    case days
    when 1 then "Daily"
    when 6..8 then "Weekly"
    when 13..15 then "Every 2 weeks"
    when 28..31 then "Monthly"
    else (days % 7).zero? ? "Every #{days / 7} weeks" : "Every #{days} days"
    end
  end

  # The hero's rhythm line: "New episode weekly, latest 9 days ago, since Sep 2017".
  def pages_rhythm(podcast)
    cadence = pages_cadence(podcast)
    # A dormant show speaks in the past tense: "Published weekly until Aug 2025, since Jan 2023" (PP-5).
    if podcast.dormant? && podcast.last_published_at
      until_month = podcast.last_published_at.strftime("%b %Y")
      parts = [ (cadence ? "published #{cadence.downcase} until #{until_month}" : "last episode #{until_month}"),
                ("since #{podcast.first_published_at.strftime('%b %Y')}" if podcast.first_published_at) ].compact
      return parts.join(", ").upcase_first
    end

    parts = [ (cadence == "Daily" ? "New episodes daily" : "New episode #{cadence.downcase}" if cadence),
              ("latest #{pages_ago(podcast.last_published_at)}" if podcast.last_published_at),
              ("since #{podcast.first_published_at.strftime('%b %Y')}" if podcast.first_published_at) ].compact
    parts.join(", ").upcase_first.presence
  end

  # The deal in one line under the hero's title (PP-3): the from price and the open months still ahead (short names,
  # "Oct" or "Oct 2026" once they span a year), from the published listing. nil when the show lists neither.
  def pages_deal(podcast)
    listing = podcast.listing if podcast.claimed? && podcast.listing&.published?
    current = Date.current.strftime("%Y-%m")
    months = Array(listing&.open_months).map(&:to_s).select { |month| month >= current }.sort.first(4)
    years = months.map { |month| month.first(4) }.uniq
    labels = months.filter_map do |month|
      date = Date.strptime(month, "%Y-%m") rescue nil
      date&.strftime(years.size > 1 ? "%b %Y" : "%b")
    end
    from = pages_money(podcast.min_price_cents) if podcast.min_price_cents
    return nil if from.nil? && labels.empty?

    { from:, months: labels }
  end

  # A long title steps the hero's display size down so it never runs to six lines (PP-4).
  def pages_title_size(title)
    length = title.to_s.length
    if length > 90 then "pod-title-long"
    elsif length > 50 then "pod-title-mid"
    end
  end

  # Podcast#stats_verified? for a whole list of cards in one query: the ids of the claimed podcasts among them with a
  # fresh verified reading. The "Stats verified" chip on a card says what the page header says.
  def pages_verified_ids(podcasts)
    ids = podcasts.select(&:claimed?).map(&:id)
    return Set.new if ids.empty?

    StatReading.unexpired.trust_verified.where(podcast_id: ids).distinct.pluck(:podcast_id).to_set
  end

  def pages_date(time) = time&.strftime("%b %-d, %Y")

  # "2026-11" => "Nov 2026" (a listing's open month).
  def pages_month(month)
    Date.strptime(month.to_s, "%Y-%m").strftime("%b %Y")
  rescue Date::Error
    nil
  end

  def pages_language(code)
    code = code.to_s.downcase.split("-").first.to_s
    LANGUAGES.fetch(code, code.upcase.presence)
  end

  # "1 h 12 min", "42 min", "50 s".
  def pages_duration(seconds)
    seconds = seconds.to_i
    return nil unless seconds.positive?

    hours, rest = seconds.divmod(3600)
    minutes = rest / 60
    return "#{seconds} s" if hours.zero? && minutes.zero?

    hours.positive? ? "#{hours} h #{minutes} min" : "#{minutes} min"
  end

  # "Season 2, episode 14", "Episode 14", "Trailer", or nil.
  def pages_episode_number(episode)
    return "Trailer" if episode.episode_type == "trailer"
    return "Bonus" if episode.episode_type == "bonus" && episode.number.nil?

    [ ("Season #{episode.season}" if episode.season), ("episode #{episode.number}" if episode.number) ].compact.join(", ").upcase_first.presence
  end

  def pages_money(cents) = cents && number_to_currency(cents / 100.0, precision: 0)

  def pages_measurement(podcast)
    Array(podcast.measurement).map { |key| MEASUREMENT_NAMES.fetch(key.to_s, key.to_s.titleize) }.presence
  end

  # The host of a URL from a feed ("example.com"), for link text that names where it goes.
  def pages_host(url)
    URI.parse(url.to_s).host&.downcase&.delete_prefix("www.")
  rescue URI::InvalidURIError
    nil
  end

  def pages_apple_url(podcast) = podcast.apple_id && "https://podcasts.apple.com/podcast/id#{podcast.apple_id}"

  # Plain text from a feed, as paragraphs: blank lines split them, single line breaks stay.
  def pages_prose(text) = simple_format(text.to_s, {}, sanitize: true)

  # The status badge: [label, tone].
  def pages_status(podcast)
    case podcast.status
    when "active" then [ "Active", :success ]
    when "dormant" then [ "Dormant", :neutral ]
    when "pending" then [ "Reading the feed", :accent ]
    when "failed" then [ "Feed unreachable", :warning ]
    end
  end

  def pages_category_link(name, **options)
    link_to name, podcast_category_path(Podcast.category_slug(name)), **options
  end

  # The search title (plan 4.1): a verified number in it when there is one (the owner's band when they chose ranges),
  # else what a buyer searches for.
  def pages_title(podcast)
    figure = podcast.public_downloads
    if figure&.verified? && (figure.band || figure.value.positive?)
      "#{podcast.title}: #{figure.text(short: true)}, verified"
    else
      "#{podcast.title} podcast sponsorship: rates, sponsors, audience"
    end
  end

  # A fact sentence for the meta description, cut to what search results show.
  def pages_description(podcast, sponsors: 0)
    facts = [ ("#{podcast.title} by #{podcast.author}." if podcast.author.present?),
              ("#{pages_cadence(podcast)}." if pages_cadence(podcast)),
              ("#{pluralize(podcast.episode_count, 'episode')}." if podcast.episode_count.to_i.positive?),
              ("#{pluralize(sponsors, 'sponsor')} in the last 90 days." if sponsors.positive?),
              ("Rate card from #{pages_money(podcast.min_price_cents)}." if podcast.min_price_cents),
              podcast.description.to_s.squish.presence ].compact
    facts.unshift("#{podcast.title}, a podcast.") if podcast.author.blank?
    facts.join(" ").truncate(DESCRIPTION_LIMIT, separator: " ")
  end

  # The page's share tags, plus noindex when the page isn't worth indexing.
  def pages_meta(description:, **options)
    tags = social_meta(description: description, **options)
    noindex? ? safe_join([ tags, tag.meta(name: "robots", content: "noindex, follow") ], "\n") : tags
  end

  # The stored artwork's absolute URL at size, for structured data; nil before it's stored.
  def pages_artwork_url(podcast, size = :large)
    variant = podcast.artwork_variant(size)
    rails_storage_proxy_url(variant) if variant
  end

  # The podcast page's JSON-LD (plan 4.1, research (e)): the PodcastSeries with its feed facts and numbers as sourced
  # PropertyValues, an Offer only when the owner published a rate card, and the breadcrumb trail. No aggregateRating.
  def pages_podcast_json_ld(podcast, sponsors: 0)
    url = podcast_url(podcast)
    series = {
      "@type" => "PodcastSeries", "@id" => "#{url}#series", "url" => url, "name" => podcast.title,
      "description" => podcast.description.to_s.squish.truncate(JSON_LD_DESCRIPTION_LIMIT).presence,
      "image" => pages_artwork_url(podcast), "webFeed" => Show.http_url(podcast.feed_url),
      "author" => ({ "@type" => "Person", "name" => podcast.author } if podcast.author.present?),
      "genre" => podcast.categories.presence, "inLanguage" => podcast.language.presence,
      "startDate" => podcast.first_published_at&.to_date&.iso8601,
      "sameAs" => [ Show.http_url(podcast.website), pages_apple_url(podcast) ].compact.presence,
      "additionalProperty" => pages_properties(podcast, sponsors: sponsors).presence,
      "offers" => pages_offer(podcast)
    }.compact
    trail = [ [ "Podcasts", podcasts_url ] ]
    trail << [ podcast.categories.first, podcast_category_url(Podcast.category_slug(podcast.categories.first)) ] if podcast.categories.first.present?
    trail << [ podcast.title, url ]
    json_ld("@context" => "https://schema.org", "@graph" => [ series, pages_breadcrumbs(trail) ])
  end

  def pages_episode_json_ld(podcast, episode)
    url = podcast_episode_url(podcast, episode)
    data = { "@type" => "PodcastEpisode", "@id" => "#{url}#episode", "url" => url, "name" => episode.title,
             "description" => episode.description.to_s.squish.truncate(JSON_LD_DESCRIPTION_LIMIT).presence,
             "datePublished" => episode.published_at&.to_date&.iso8601,
             "duration" => (ActiveSupport::Duration.build(episode.duration_seconds).iso8601 if episode.duration_seconds.to_i.positive?),
             "episodeNumber" => episode.number, "image" => pages_artwork_url(podcast),
             "associatedMedia" => ({ "@type" => "MediaObject", "contentUrl" => Show.http_url(episode.enclosure_url) } if Show.http_url(episode.enclosure_url)),
             "partOfSeries" => { "@type" => "PodcastSeries", "@id" => "#{podcast_url(podcast)}#series", "name" => podcast.title,
                                 "url" => podcast_url(podcast) } }.compact
    trail = [ [ "Podcasts", podcasts_url ], [ podcast.title, podcast_url(podcast) ], [ episode.title, url ] ]
    json_ld("@context" => "https://schema.org", "@graph" => [ data, pages_breadcrumbs(trail) ])
  end

  # A listing page (a category, a brand's shows): an ItemList of its podcast pages and the breadcrumb trail.
  def pages_list_json_ld(name:, url:, podcasts:, trail:)
    items = podcasts.each_with_index.map do |podcast, index|
      { "@type" => "ListItem", "position" => index + 1, "url" => podcast_url(podcast), "name" => podcast.title }
    end
    json_ld("@context" => "https://schema.org",
            "@graph" => [ { "@type" => "ItemList", "@id" => "#{url}#list", "name" => name, "url" => url, "itemListElement" => items },
                          pages_breadcrumbs(trail) ])
  end

  # The downloads figure named by its source (plays when read from Spotify and Apple, downloads when the show gave it),
  # as a range when the owner chose ranges.
  def pages_downloads_property(figure)
    return nil unless figure

    property = { "@type" => "PropertyValue", "name" => "#{figure.unit.capitalize} per episode",
                 "description" => (figure.verified? ? VERIFIED_PLAYS : PROVIDED_DOWNLOADS) }
    return property.merge("value" => figure.value) unless figure.band

    range = figure.range
    max = range.end && (range.exclude_end? ? range.end - 1 : range.end)
    property.merge("minValue" => range.begin, "maxValue" => max).compact
  end

  private

  def pages_breadcrumbs(trail)
    { "@type" => "BreadcrumbList",
      "itemListElement" => trail.each_with_index.map { |(name, item), index| { "@type" => "ListItem", "position" => index + 1, "name" => name, "item" => item } } }
  end

  # Each number with where it came from and when (the TrustMRR pattern).
  def pages_properties(podcast, sponsors:)
    checked = podcast.feed_checked_at&.to_date&.iso8601
    [ ({ "@type" => "PropertyValue", "name" => "Episodes", "value" => podcast.episode_count,
         "description" => [ "From the show's RSS feed", checked && "checked #{checked}" ].compact.join(", ") } if podcast.episode_count.to_i.positive?),
      ({ "@type" => "PropertyValue", "name" => "Sponsors in the last 90 days", "value" => sponsors,
         "description" => "Sponsor reads found in the show notes" } if sponsors.positive?),
      pages_downloads_property(podcast.public_downloads) ].compact
  end

  # The cheapest spot on a published rate card (refresh_listing! sets min_price_cents only then).
  def pages_offer(podcast)
    return nil unless podcast.min_price_cents

    { "@type" => "Offer", "name" => "Podcast sponsorship", "price" => (podcast.min_price_cents / 100.0).round(2),
      "priceCurrency" => "USD", "url" => "#{podcast_url(podcast)}#rates",
      "availability" => podcast.open_to_sponsors? ? "https://schema.org/InStock" : "https://schema.org/OutOfStock" }
  end
end
