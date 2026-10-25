# Formatting for the media kit pages (media_kits/, public_kits/). The data comes from MediaKit::Content.
module MediaKitsHelper
  WAVE_BARS = 72
  WAVE_UNIT = 10

  def kit_money(amount) = number_to_currency(amount, precision: 0)

  # [[value, label]] for the stats the show has: self-reported downloads, episode count, cadence from the feed.
  def kit_stats(content)
    show = content.show
    [
      ([ number_with_delimiter(show.downloads_per_episode), "downloads per episode" ] if show.downloads_per_episode),
      ([ number_with_delimiter(show.episode_count), "episodes" ] if show.episode_count.to_i.positive?),
      ([ content.cadence, "new episodes" ] if content.cadence)
    ].compact
  end

  # The feed's host for the verified-owner line (R58): only the host, lowercased, never the path or query.
  def kit_feed_host(show)
    uri = URI.parse(show.feed_url.to_s.strip)
    uri.host&.downcase.presence if uri.is_a?(URI::HTTP)
  rescue URI::InvalidURIError
    nil
  end

  # The URL of a saved image's variant, or nil. An upload that failed validation is still in memory, unsaved.
  def kit_image_url(attachment, variant)
    url_for(attachment.variant(variant)) if attachment.attached? && attachment.blob.persisted?
  end

  # "Run a mid-roll in 4 episodes for $415, 10% off."
  def kit_bundle_line(rates)
    config = Rails.application.config_for(:rate_card)
    safe_join([ "Run a mid-roll in #{config[:bundle_episodes]} episodes for ", tag.strong(kit_money(rates.bundle4)),
                ", #{(config[:bundle_discount] * 100).round}% off." ])
  end

  def kit_rate_note(content, rates)
    rates.custom? ? "Rates set by #{content.show.title}." : "#{rates.basis}."
  end

  # The banner when there is no cover: a waveform unique to the show (seeded by its id), its middle bar lit
  # amber where the mid-roll sits. Decorative.
  def kit_waveform(seed)
    random = Random.new(Zlib.crc32(seed.to_s))
    middle = WAVE_BARS / 2
    level = 0.5
    bars = Array.new(WAVE_BARS) do |i|
      level = (level * 0.55 + random.rand * 0.45).clamp(0.12, 1.0)
      height = i == middle ? 92 : (18 + level * 64).round
      tag.rect(x: i * WAVE_UNIT + 2, y: (100 - height) / 2.0, width: 6, height: height, rx: 3,
               class: i == middle ? "kit-wave-mid" : "kit-wave-bar")
    end
    tag.svg(safe_join(bars), viewBox: "0 0 #{WAVE_BARS * WAVE_UNIT} 100", preserveAspectRatio: "xMidYMid slice",
                             class: "kit-wave", aria: { hidden: true }, focusable: "false")
  end
end
