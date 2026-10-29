# Verified stats (build spec section 11): Midrolo's service accounts are invited to a show's Spotify for Creators or
# Apple Podcasts Connect analytics, and read its numbers through bin/platform-stats. The platforms of this slice and
# the words used for them everywhere.
module Stats
  PLATFORMS = {
    "spotify" => { name: "Spotify", service: "Spotify for Creators", session_keys: %w[sp_dc sp_key],
                   required_keys: %w[sp_dc] },
    "apple" => { name: "Apple Podcasts", service: "Apple Podcasts Connect", session_keys: %w[myacinfo itctx],
                 required_keys: %w[myacinfo itctx] }
  }.freeze

  # Where each platform's show ids look like this (what bin/platform-stats accepts).
  SHOW_IDS = { "spotify" => /\A[A-Za-z0-9]{22}\z/, "apple" => /\A\d{1,15}\z/ }.freeze

  module_function

  def platform?(provider) = PLATFORMS.key?(provider.to_s)

  # "Spotify", "Apple Podcasts".
  def platform_name(provider) = PLATFORMS.dig(provider.to_s, :name) || provider.to_s.humanize

  # "Spotify for Creators", "Apple Podcasts Connect": the service a verified number comes from.
  def service_name(provider) = PLATFORMS.dig(provider.to_s, :service) || provider.to_s.humanize

  # The address podcasters invite, per platform (env, defaulting to stats@midrolo.com).
  def invite_email(provider)
    value = provider.to_s == "apple" ? ENV["MIDROLO_APPLE_EMAIL"] : ENV["MIDROLO_SPOTIFY_EMAIL"]
    value.to_s.strip.presence || "stats@midrolo.com"
  end

  # The platform's show id in what a podcaster pasted: a show link (open.spotify.com/show/ID,
  # podcasts.apple.com/.../idNNN), a spotify:show:ID URI, or the bare id. nil when there isn't one.
  def show_id_from(provider, input)
    text = input.to_s.strip
    id = case provider.to_s
    when "spotify" then text[%r{(?:open\.spotify\.com/(?:[a-z-]+/)?show/|spotify:show:)([A-Za-z0-9]{22})}i, 1] || text
    when "apple" then text[%r{podcasts\.apple\.com/\S*?/id(\d{1,15})}i, 1] || text[/\Aid(\d{1,15})\z/i, 1] || text
    end
    id if id && SHOW_IDS.fetch(provider.to_s).match?(id)
  end

  # The show's public page on the platform, for links in the admin queue.
  def show_url(provider, show_id)
    case provider.to_s
    when "spotify" then "https://open.spotify.com/show/#{show_id}"
    when "apple" then "https://podcasts.apple.com/podcast/id#{show_id}"
    end
  end
end
