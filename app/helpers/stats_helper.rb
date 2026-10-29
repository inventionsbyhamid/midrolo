# Verified stats on pages (build spec section 11): every number says where it came from and when, the way TrustMRR does
# (number, source, date). trust_badge is the badge; stats/_number is a number with its label; podcasts/_numbers is the
# podcast page's key numbers strip and stats/_audience its verified audience card. Lane L5's other helpers start with
# stats_.
module StatsHelper
  # What each trust level is called on a badge, and its tone.
  TRUST_BADGES = {
    "verified" => [ "Verified", :success ],
    "provided" => [ "Provided by the show", :neutral ],
    "public" => [ "Public", :accent ],
    "feed" => [ "From the feed", :neutral ]
  }.freeze

  # Owners who'd rather not show exact numbers (media_kits.bands_only) show these.
  BANDS = [ [ 500, "0 to 500" ], [ 1_000, "500 to 1,000" ], [ 2_500, "1,000 to 2,500" ], [ 5_000, "2,500 to 5,000" ],
            [ 10_000, "5,000 to 10,000" ] ].freeze
  TOP_BAND = "10,000+".freeze

  METRIC_LABELS = {
    "streams_30d" => "streams, 30 days", "starts_30d" => "starts, 30 days", "listeners_30d" => "listeners, 30 days",
    "plays_30d" => "plays, 30 days", "engaged_listeners_30d" => "engaged listeners, 30 days",
    "streams_all_time" => "streams, all time", "starts_all_time" => "starts, all time",
    "listeners_all_time" => "listeners, all time", "plays_all_time" => "plays, all time", "followers" => "followers"
  }.freeze

  AGE_LABELS = { "0-17" => "Under 18", "60+" => "60 and over", "unknown" => "Unknown" }.freeze
  GENDER_LABELS = { "female" => "Women", "male" => "Men", "non_binary" => "Non binary", "not_specified" => "Not specified" }.freeze
  COUNTRY_NAMES = <<~LIST.lines.to_h { |line| line.strip.split(":", 2) }.freeze
    US:United States
    GB:United Kingdom
    CA:Canada
    AU:Australia
    NZ:New Zealand
    IE:Ireland
    IN:India
    DE:Germany
    FR:France
    ES:Spain
    IT:Italy
    NL:Netherlands
    BE:Belgium
    CH:Switzerland
    AT:Austria
    SE:Sweden
    NO:Norway
    DK:Denmark
    FI:Finland
    IS:Iceland
    PL:Poland
    PT:Portugal
    CZ:Czechia
    GR:Greece
    HU:Hungary
    RO:Romania
    UA:Ukraine
    TR:Turkey
    IL:Israel
    AE:United Arab Emirates
    SA:Saudi Arabia
    EG:Egypt
    NG:Nigeria
    KE:Kenya
    ZA:South Africa
    GH:Ghana
    MA:Morocco
    MX:Mexico
    BR:Brazil
    AR:Argentina
    CL:Chile
    CO:Colombia
    PE:Peru
    JP:Japan
    KR:South Korea
    CN:China
    HK:Hong Kong
    TW:Taiwan
    SG:Singapore
    MY:Malaysia
    ID:Indonesia
    PH:Philippines
    TH:Thailand
    VN:Vietnam
    PK:Pakistan
    BD:Bangladesh
    LK:Sri Lanka
  LIST

  # The badge naming how far to trust a number and where it came from (build spec section 4). reading_or_level is a
  # StatReading (its source and capture date are used unless source: or at: say otherwise) or a level from
  # StatReading::TRUST_LEVELS. A verified reading that has expired says "Last verified" with its date instead.
  def trust_badge(reading_or_level, source: nil, at: nil)
    reading = reading_or_level if reading_or_level.is_a?(StatReading)
    level = reading ? reading.trust : reading_or_level.to_s
    source = source.presence || (stats_source_name(reading).presence if reading)
    at ||= reading&.captured_at
    label, tone = TRUST_BADGES.fetch(level, [ level.humanize, :neutral ])
    if reading&.trust_verified? && reading.expired?
      label = at ? "Last verified #{stats_date(at)}" : "Last verified"
      tone = :neutral
      at = nil
    end

    details = [ (level == "verified" && !reading&.expired? && source ? "with #{source}" : source), (stats_date(at) if at) ].compact
    tag.span(class: "inline-flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-ink-soft") do
      safe_join([
        tag.span(class: [ "badge", UiHelper::BADGE_TONES.fetch(tone) ]) { safe_join([ stats_badge_icon(level, tone), label ].compact) },
        (ui_badge("Demo", tone: :warning) if reading&.evidence&.dig("demo")),
        (tag.span(safe_join(details, " · ")) if details.any?)
      ].compact, " ")
    end
  end

  # The page's numbers for podcast, loaded once per request.
  def stats_page_numbers(podcast)
    @stats_page_numbers ||= {}
    @stats_page_numbers[podcast.id] ||= Stats::PageNumbers.new(podcast)
  end

  # The header's "Stats verified" pill, when the claimed podcast has a fresh verified reading; nothing otherwise.
  def stats_verified_pill(podcast)
    return unless stats_page_numbers(podcast).verified?

    tag.span(class: "badge badge-success", title: "Numbers read from Spotify for Creators or Apple Podcasts Connect by Midrolo") do
      safe_join([ stats_badge_icon("verified", :success), "Stats verified" ])
    end
  end

  # "Spotify listeners, 30 days", "Spotify and Apple plays per episode, 30 days", "Downloads per episode".
  def stats_metric_label(reading)
    if reading.metric == StatReading::DOWNLOADS_PER_EPISODE
      return "Downloads per episode" unless reading.source == Podcast::Stats::PLAYS_SOURCE

      names = Array(reading.evidence["sources"]).map { |source| stats_short_name(source) }
      return "#{Copy.and_list(names.presence || [ 'Platform' ])} plays per episode, 30 days"
    end

    words = METRIC_LABELS[reading.metric] || reading.metric.humanize.downcase
    Stats.platform?(reading.source) ? "#{stats_short_name(reading.source)} #{words}" : words.upcase_first
  end

  # "Spotify", "Apple": how a number's label names its platform ("Apple plays, 30 days").
  def stats_short_name(provider) = provider.to_s == "apple" ? "Apple" : Stats.platform_name(provider)

  # Where a reading came from, in words: "Spotify for Creators", "Spotify for Creators and Apple Podcasts Connect",
  # "the show".
  def stats_source_name(reading)
    case reading.source
    when Podcast::Stats::PLAYS_SOURCE then Copy.and_list(Array(reading.evidence["sources"]).map { |source| Stats.service_name(source) })
    when Podcast::Stats::PROVIDED_SOURCE then nil
    else Stats.platform?(reading.source) ? Stats.service_name(reading.source) : reading.source.to_s.humanize
    end
  end

  # The number as shown: grouped digits, or the owner's band.
  def stats_value(reading, bands: false)
    bands ? stats_band(reading.value) : number_with_delimiter(reading.value)
  end

  def stats_band(value)
    BANDS.find { |limit, _label| value.to_i < limit }&.last || TOP_BAND
  end

  # "Oct 29", or "Oct 29, 2025" for another year.
  def stats_date(time)
    time = time.in_time_zone("UTC")
    time.year == Time.current.utc.year ? time.strftime("%b %-d") : time.strftime("%b %-d, %Y")
  end

  # A connection's status on the stats screen: its badge text and tone.
  def stats_connection_badge(connection)
    label, tone = case connection.status
    when "pending_invite" then [ "Waiting for access", :warning ]
    when "active" then [ "Connected", :success ]
    when "mismatch" then [ "Doesn't match", :danger ]
    when "failed" then [ "Couldn't connect", :danger ]
    else [ "Access removed", :danger ]
    end
    ui_badge(label, tone: tone)
  end

  def stats_age_label(key) = AGE_LABELS.fetch(key.to_s) { key.to_s.sub(/\A(\d+)-(\d+)\z/, '\1 to \2') }

  def stats_gender_label(key) = GENDER_LABELS.fetch(key.to_s) { key.to_s.humanize }

  def stats_country_name(code) = code.to_s == "other" ? "Elsewhere" : COUNTRY_NAMES.fetch(code.to_s.upcase, code.to_s.upcase)

  # The share rows of an audience breakdown, largest first, for meters: [[label, share, scaled], ...], where scaled is
  # the share against the largest (so the longest bar fills the track).
  def stats_share_rows(shares, limit: 8, &label)
    rows = shares.to_h.reject { |key, share| share.to_f <= 0 || (key == "unknown" && share.to_f < 0.01) }
                 .sort_by { |_key, share| -share.to_f }.first(limit)
    top = rows.first&.last.to_f
    rows.map { |key, share| [ label.call(key), share.to_f, top.positive? ? share.to_f / top : 0 ] }
  end

  def stats_percent(share) = share < 0.01 ? "<1%" : "#{(share * 100).round}%"

  private

  def stats_badge_icon(level, tone)
    return unless level == "verified" && tone == :success

    tag.svg(viewBox: "0 0 16 16", class: "size-3.5", aria: { hidden: true }, fill: "none", stroke: "currentColor",
            "stroke-width": "2.25", "stroke-linecap": "round", "stroke-linejoin": "round") do
      tag.path(d: "M3.5 8.5l3 3 6-7")
    end
  end
end
