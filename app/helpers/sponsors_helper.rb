# Sponsor history on public pages (lane L2; every helper starts with sponsors_): when a brand was seen, and links to
# the podcast, episode and brand pages (lane L3's routes, config/routes/catalog.rb).
module SponsorsHelper
  # Brands a podcast page lists before "Show more".
  SHOWN = 8

  # When a sponsor was seen: "Mar 2026 to Oct 2026", "Oct 2026" (one month), "Oct 3, 2026" (one day); nil undated.
  def sponsors_period(row)
    first, last = row.first_seen, row.last_seen
    return nil unless last
    return last.strftime("%b %-d, %Y") if first.nil? || first.to_date == last.to_date
    return last.strftime("%b %Y") if first.strftime("%Y-%m") == last.strftime("%Y-%m")

    "#{first.strftime('%b %Y')} to #{last.strftime('%b %Y')}"
  end

  def sponsors_podcast_path(podcast) = podcast_path(podcast)

  def sponsors_episode_path(podcast, episode_slug) = (podcast_episode_path(podcast, episode_slug) if episode_slug.present?)

  # The public brand page, /brands/:slug (a brand's to_param is its public id).
  def sponsors_brand_path(brand) = public_brand_path(brand.slug)

  # The brand's site as plain text ("drinkag1.com"); never a link built from feed text.
  def sponsors_domain(brand) = brand.domain.presence
end
