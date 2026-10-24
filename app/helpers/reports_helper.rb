# Formatting for the report sections (app/views/reports/sections). Section data is jsonb, so hashes arrive with
# string keys; the shapes are documented in Research::AudienceProfile and Research::Tools::Save*.
module ReportsHelper
  TIERS = { "easy_yes" => [ "Easy yes", :success ], "realistic" => [ "Realistic", :accent ],
            "long_shot" => [ "Long shot", :warning ] }.freeze
  HIGH_FIT = 75
  AUDIENCE_TABS = { "brands" => "Brands", "artists" => "Music", "tv_shows" => "TV", "podcasts" => "Podcasts",
                    "tags" => "Taste tags" }.freeze
  GENDERS = { "male" => "Men", "female" => "Women" }.freeze
  # Leans are relative skews (about -1..1), never shares of a headcount, so they read as words.
  EVEN_BELOW = 0.05
  STRONG_FROM = 0.25
  LEAN_SEGMENTS = 10
  LEAN_SCALE_FLOOR = 0.5
  TOP_METROS = 8
  PROVEN_SHOWN = 2
  DEFAULT_MAP_STYLE_URL = "https://tiles.openfreemap.org/styles/positron".freeze

  # True while the run may still fill a section in; finished reports hide sections that never came.
  def section_pending?(report) = report.active?

  def tier_label(tier) = TIERS.fetch(tier.to_s, [ tier.to_s.humanize ]).first

  def tier_badge(tier) = ui_badge(tier_label(tier), tone: TIERS.fetch(tier.to_s, [ nil, :neutral ]).last)

  def tier_rank(tier) = TIERS.keys.index(tier.to_s) || TIERS.size

  def fit_bucket(fit_score) = fit_score.to_i >= HIGH_FIT ? "High fit" : "Good fit"

  # "Fieldnote Coffee" -> "FC"
  def initials_for(name)
    name.to_s.split.filter_map { |word| word[/\p{Alnum}/] }.first(2).join.upcase.presence || "?"
  end

  # Only http(s) URLs from taste data reach an href or src.
  def safe_external_url(url)
    uri = URI.parse(url.to_s.strip)
    uri.to_s if uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end

  def display_host(url)
    URI.parse(url.to_s).host.to_s.delete_prefix("www.")
  rescue URI::InvalidURIError
    url.to_s
  end

  # ---- Audience ----

  # [[key, label, items]] for the lists that came back (a snapshot has only tags).
  def audience_tabs(audience)
    AUDIENCE_TABS.filter_map do |key, label|
      items = Array(audience.is_a?(Hash) ? audience[key] : nil).select { |item| item.is_a?(Hash) && item["name"].present? }
      [ key, label, items ] if items.any?
    end
  end

  # ---- Leans ----

  def age_bucket_label(bucket)
    case bucket.to_s
    when /\A(\d+)_to_(\d+)\z/ then "#{$1}–#{$2}"
    when /\A(\d+)_and_younger\z/ then "#{$1} and under"
    when /\A(\d+)_and_older\z/ then "#{$1}+"
    else bucket.to_s.humanize
    end
  end

  # jsonb hands keys back shortest first ("24_and_younger" last), so buckets are ordered by their first age.
  def age_buckets_in_order(leans) = leans.sort_by { |bucket, _| [ bucket.to_s[/\d+/].to_i, bucket.to_s ] }

  def gender_label(gender) = GENDERS.fetch(gender.to_s, gender.to_s.humanize)

  def lean_direction(value)
    value = value.to_f
    return "even" if value.abs < EVEN_BELOW

    value.positive? ? "over" : "under"
  end

  def lean_word(value)
    value = value.to_f
    return "About even" if value.abs < EVEN_BELOW

    strong = value.abs >= STRONG_FROM
    if value.positive?
      strong ? "Over-indexes" : "Slightly over"
    else
      strong ? "Under-indexes" : "Slightly under"
    end
  end

  # Segments lit on one side of the center line. The scale is the strongest lean on the page (at least 0.5),
  # so small leans stay small and any real lean lights at least one segment.
  def lean_segments(value, scale)
    value = value.to_f.abs
    return 0 if value < EVEN_BELOW

    (value / scale * LEAN_SEGMENTS).round.clamp(1, LEAN_SEGMENTS)
  end

  def lean_scale(demographics)
    values = demographics.values.select { |group| group.is_a?(Hash) }.flat_map(&:values).map { |v| v.to_f.abs }
    [ values.max.to_f, LEAN_SCALE_FLOOR ].max
  end

  # ---- Map ----

  def heatmap_points(heatmap)
    Array(heatmap.is_a?(Hash) ? heatmap["points"] : nil).select { |p| p.is_a?(Hash) && p["lat"] && p["lng"] }
  end

  # [[label, share of the top metro's summed affinity (0..1)]], strongest first.
  def top_metros(points, limit: TOP_METROS)
    totals = points.select { |p| p["label"].present? }
                   .group_by { |p| p["label"] }
                   .map { |label, group| [ label, group.sum { |p| p["affinity"].to_f } ] }
                   .sort_by { |label, total| [ -total, label ] }
                   .first(limit)
    top = totals.first&.last.to_f
    totals.map { |label, total| [ label, top.positive? ? total / top : 0.0 ] }
  end

  # The country's name, or nil when the section doesn't say ("metros" with no country).
  def heatmap_country(heatmap)
    code = (heatmap["location"] == "metros" ? heatmap["country"] : heatmap["location"]).to_s.strip
    Show::COUNTRIES.fetch(code.upcase, code).presence
  end

  # "United States", "United States metros", or nil.
  def heatmap_place(heatmap)
    country = heatmap_country(heatmap)
    country && heatmap["location"] == "metros" ? "#{country} metros" : country
  end

  def heatmap_label(heatmap)
    country = heatmap_country(heatmap)
    "Heatmap of where people with your listeners' tastes live#{" in #{country}" if country}"
  end

  def map_style_url = ENV["MAP_STYLE_URL"].presence || DEFAULT_MAP_STYLE_URL

  # The stylesheet that ships with the pinned MapLibre build (same version, same folder). map_controller links it
  # when it imports the library, so report pages don't wait on it for first paint.
  def maplibre_stylesheet_url
    Rails.application.importmap.packages.fetch("maplibre-gl").path.sub(/\.mjs\z/, ".css")
  end

  # ---- Matches ----

  def proven_evidence(match) = Matching::Evidence.value(match.evidence, :proven)

  def proven_sponsor?(match)
    proven = proven_evidence(match)
    Matching::Evidence.count(proven).positive? || Matching::Evidence.items(proven).any?
  end

  # "Shares 6 taste tags", "Affinity 0.82", "Sponsored <em>Show X</em> · Oct 12" (newest two), "+2 more".
  def evidence_chips(match)
    chips = []
    shared = Array(Matching::Evidence.value(match.evidence, :shared_tags))
    chips << "Shares #{pluralize(shared.size, 'taste tag')}" if shared.any?
    chips << "Affinity #{format('%.2f', match.affinity)}" if match.affinity
    proven = proven_evidence(match)
    items = Matching::Evidence.items(proven).first(PROVEN_SHOWN)
    items.each { |item| chips << sponsored_chip(item) }
    more = Matching::Evidence.count(proven) - items.size
    chips << "+#{more} more" if items.any? && more.positive?
    chips
  end

  private

  def sponsored_chip(item)
    show = Matching::Evidence.value(item, :show).presence || "a similar show"
    date = Matching::Evidence.published_at(item)
    parts = [ "Sponsored ", tag.em(show) ]
    parts += [ " · ", date.year == Time.current.year ? date.strftime("%b %-d") : date.strftime("%b %-d, %Y") ] if date
    safe_join(parts)
  end
end
