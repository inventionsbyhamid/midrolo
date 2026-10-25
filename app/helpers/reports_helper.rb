# Formatting for the report sections (app/views/reports/sections). Section data is jsonb, so hashes arrive with
# string keys; the shapes are documented in Research::AudienceProfile and Research::Tools::Save*.
module ReportsHelper
  TIER_TONES = { "easy_yes" => :success, "realistic" => :accent, "long_shot" => :warning }.freeze
  # tier => [label, badge tone], in tier order.
  TIERS = Matching::Tier::LABELS.to_h { |tier, label| [ tier, [ label, TIER_TONES.fetch(tier) ] ] }.freeze
  HIGH_FIT = 75
  # What each tier means for the podcaster, in the match's Why it fits.
  TIER_HINTS = { "easy_yes" => "a smaller brand, likely to welcome a show this size",
                 "realistic" => "a mid-size brand, so lead with the fit",
                 "long_shot" => "a big brand, so keep the ask small and concrete" }.freeze
  # The audience's lists, in the order their chips and lists read: the interests describe the audience best.
  AUDIENCE_GROUPS = { "tags" => "Interests", "brands" => "Brands", "podcasts" => "Podcasts", "tv_shows" => "TV",
                      "artists" => "Music" }.freeze
  TOP_TASTES = 8
  # A Qloo score (0 to 1) in words: how much more this audience likes something than most people do (R99). Qloo
  # gives a score, not a ratio, so the words grade it without inventing a multiple.
  TASTE_BANDS = [ [ 0.9, "Far more than most" ], [ 0.75, "Much more than most" ], [ 0.5, "More than most" ],
                  [ 0.0, "Somewhat more than most" ] ].freeze
  GENDERS = { "male" => "Men", "female" => "Women" }.freeze
  # Leans are relative skews (about -1..1), never shares of a headcount, so they read as words.
  EVEN_BELOW = 0.05
  STRONG_FROM = 0.25
  LEAN_SEGMENTS = 10
  LEAN_SCALE_FLOOR = 0.5
  TOP_METROS = 8
  TOP_PLACES = 3
  MAX_CHIPS = 3
  TOP_MATCHES = 10
  DEFAULT_MAP_STYLE_URL = "https://tiles.openfreemap.org/styles/positron".freeze

  # Who a report's copy talks about: "your listeners" to the show's owner, "this show's listeners" on a public sample
  # (read_only, R78), so a stranger never reads "your". Agent-written text (the summary, reasons) stays as written.
  def report_listeners(read_only) = read_only ? "this show's listeners" : "your listeners"

  # True while the run may still fill a section in; finished reports hide sections that never came.
  def section_pending?(report) = report.active?

  # "A, B and C" from html-safe parts (links), with no comma before the "and".
  def and_join(parts)
    return safe_join(parts) if parts.size < 2

    safe_join([ safe_join(parts[0...-1], ", "), " and ", parts.last ])
  end

  # At a glance's audience line when there is no summary (a Snapshot): its top three interests, as a group (R99).
  def glance_audience(report)
    names = audience_groups(report.audience).find { |key, _, _| key == "tags" }&.last.to_a.first(3).map { |tag| tag["name"] }
    "This audience leans toward #{names.to_sentence(last_word_connector: ' and ')}." if names.any?
  end

  def tier_label(tier) = TIERS.fetch(tier.to_s, [ tier.to_s.humanize ]).first

  # nil for a missing or unknown tier, so no empty badge renders.
  def tier_badge(tier)
    label, tone = TIERS[tier.to_s]
    ui_badge(label, tone: tone) if label
  end

  # [[label, count]] for the known tiers among locked matches, in tier order; unknown tiers are skipped.
  def locked_tier_counts(matches)
    counts = matches.map { |m| m.tier.to_s }.tally
    TIERS.filter_map { |tier, (label, _)| [ label, counts[tier] ] if counts[tier] }
  end

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
  def audience_groups(audience)
    AUDIENCE_GROUPS.filter_map do |key, label|
      items = Array(audience.is_a?(Hash) ? audience[key] : nil).select { |item| item.is_a?(Hash) && item["name"].present? }
      [ key, label, items ] if items.any?
    end
  end

  # Up to limit names from [[label, names]], taken from each group in turn so every kind shows, and handed back
  # grouped in the groups' order: [[label, names]].
  def top_tastes(groups, limit: TOP_TASTES)
    picked = groups.map { [] }
    depth = 0
    while picked.sum(&:size) < limit && groups.any? { |_, names| names.size > depth }
      groups.each_with_index do |(_, names), i|
        picked[i] << names[depth] if names.size > depth && picked.sum(&:size) < limit
      end
      depth += 1
    end
    groups.each_with_index.filter_map { |(label, _), i| [ label, picked[i] ] if picked[i].any? }
  end

  def taste_band(score)
    return if score.nil?

    TASTE_BANDS.find { |floor, _| score.to_f >= floor }&.last || TASTE_BANDS.last.last
  end

  # ---- Leans ----

  def age_bucket_label(bucket)
    case bucket.to_s
    when /\A(\d+)_to_(\d+)\z/ then "#{$1} to #{$2}"
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
    return "About average" if value.abs < EVEN_BELOW

    strong = value.abs >= STRONG_FROM
    if value.positive?
      strong ? "Well above average" : "A bit above average"
    else
      strong ? "Well below average" : "A bit below average"
    end
  end

  # "Leans strongly toward men", "Leans a little toward women" or "About even between men and women"; nil without data.
  def gender_line(leans)
    return unless leans.is_a?(Hash) && leans.any?

    gender, value = leans.max_by { |_, lean| lean.to_f }
    return "About even between men and women" if value.to_f < EVEN_BELOW

    "Leans #{value.to_f >= STRONG_FROM ? 'strongly' : 'a little'} toward #{gender_label(gender).downcase}"
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

  # "Austin, Denver and Boise": the strongest places in words, or nil.
  def top_places(points, limit: TOP_PLACES)
    top_metros(points, limit: limit).map(&:first).to_sentence(last_word_connector: " and ").presence
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

  # [visible, locked]: a Snapshot shows only the plan's visible limit and locks the rest, in report order (R43); an
  # agent report stays whole for its owner (R44, R64). Asked once per report per render: At a glance and the matches
  # both need it.
  def split_matches(report)
    @split_matches ||= {}
    @split_matches[report.id] ||= begin
      matches = report.sponsor_matches.to_a
      limit = report.snapshot? ? Entitlements.for(report.show.user).visible_matches_limit : matches.size
      [ matches.first(limit), matches.drop(limit) ]
    end
  end

  def proven_evidence(match) = Matching::Evidence.value(match.evidence, :proven)

  def proven_sponsor?(match)
    proven = proven_evidence(match)
    Matching::Evidence.count(proven).positive? || Matching::Evidence.items(proven).any?
  end

  def shared_tastes(match) = Array(Matching::Evidence.value(match.evidence, :shared_tags)).compact_blank

  # At most three: "Shares 6 tastes", "Sponsors <em>Show X</em>" (the newest), "+2 more". No scores (R99).
  def evidence_chips(match)
    chips = []
    shared = shared_tastes(match)
    chips << "Shares #{pluralize(shared.size, 'taste')}" if shared.any?
    proven = proven_evidence(match)
    item = Matching::Evidence.items(proven).first
    if item
      chips << safe_join([ "Sponsors ", tag.em(Matching::Evidence.value(item, :show).presence || "a similar show") ])
      more = Matching::Evidence.count(proven) - 1
      chips << "+#{more} more" if more.positive?
    end
    chips.first(MAX_CHIPS)
  end

  # The reason's one line on the row: as written when it fits the 25 words, else its first sentence (older reports).
  def match_reason_line(match)
    reason = match.reason.to_s.squish.presence
    reason && Llm::PlainText.clip_words(reason, SponsorMatch::REASON_WORDS)
  end

  def tier_hint(tier) = TIER_HINTS[tier.to_s]

  # "Sponsored <em>Harbor Lights</em> on “Cash flow surprises”, Oct 12" for one proven item.
  def proven_item_line(item)
    show = Matching::Evidence.value(item, :show).presence || "a similar show"
    episode = Matching::Evidence.value(item, :episode_title).presence
    date = Matching::Evidence.published_at(item)
    parts = [ "Sponsored ", tag.em(show) ]
    parts += [ " on “", episode, "”" ] if episode
    parts += [ ", ", date.year == Time.current.year ? date.strftime("%b %-d") : date.strftime("%b %-d, %Y") ] if date
    safe_join(parts)
  end
end
