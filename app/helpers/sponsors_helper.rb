# Sponsor history on public pages (lane L2; every helper starts with sponsors_): when a brand was seen, and links to
# the podcast, episode and brand pages. Those routes are lane L3's (config/routes/catalog.rb); until they're drawn the
# paths are built from the same URL shapes.
module SponsorsHelper
  # Brands a podcast page lists before "Show more".
  SHOWN = 8

  # "4 episodes, Mar 2026 to Oct 2026", or "1 episode, Oct 3, 2026".
  def sponsors_seen(row)
    count = pluralize(row.episodes_count, "episode")
    first, last = row.first_seen, row.last_seen
    return count unless last
    return "#{count}, #{last.strftime('%b %-d, %Y')}" if first.nil? || first.to_date == last.to_date
    return "#{count}, #{first.strftime('%b %Y')}" if first.strftime("%Y-%m") == last.strftime("%Y-%m")

    "#{count}, #{first.strftime('%b %Y')} to #{last.strftime('%b %Y')}"
  end

  def sponsors_podcast_path(podcast)
    respond_to?(:podcast_path) ? podcast_path(podcast) : "/podcasts/#{ERB::Util.url_encode(podcast.to_param)}"
  end

  def sponsors_episode_path(podcast, episode_slug)
    return nil if episode_slug.blank?

    if respond_to?(:podcast_episode_path)
      podcast_episode_path(podcast, episode_slug)
    else
      "/podcasts/#{ERB::Util.url_encode(podcast.to_param)}/episodes/#{ERB::Util.url_encode(episode_slug)}"
    end
  end

  def sponsors_brand_path(brand)
    respond_to?(:public_brand_path) ? public_brand_path(brand.slug) : "/brands/#{ERB::Util.url_encode(brand.slug)}"
  end

  # The brand's site as plain text ("drinkag1.com"); never a link built from feed text.
  def sponsors_domain(brand) = brand.domain.presence
end
