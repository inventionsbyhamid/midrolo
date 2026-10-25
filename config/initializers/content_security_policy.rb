# The Content Security Policy (spec §9a, R10, R116), enforced in every environment so specs see what production sends.
# What the pages load, and from where:
# - scripts: the app's own (importmap), and MapLibre from the one jsDelivr folder config/importmap.rb pins
#   (https://cdn.jsdelivr.net/npm/maplibre-gl@<version>/), never the rest of jsDelivr; bumping the pin moves the
#   policy with it. The importmap and the module that starts the app are inline, so they carry the page's nonce; Turbo
#   gives the same nonce to the scripts it adds and to its progress bar's <style>, read from the csp-nonce meta tag.
# - styles: the app's stylesheet, Google Fonts' Archivo stylesheet, MapLibre's stylesheet from its pinned folder. No
#   style attributes in the views: the policy blocks them.
# - fonts: Archivo from fonts.gstatic.com.
# - images: any https host (feed artwork, sponsor logos, Google avatars, kit photos on R2 behind Active Storage's
#   redirects), data: (icons inlined in CSS), blob: (MapLibre).
# - fetches: the map's style, tiles, glyphs and sprites from OpenFreeMap, plus MAP_STYLE_URL's host when it names
#   another. Action Cable's wss:// to this host counts as 'self'. (The test environment alone adds data:, for the
#   inline map style some system specs use: config/environments/test.rb.)
# - workers: MapLibre starts its worker from its pinned folder (and, in some builds, from a blob: URL).
# No form-action: sign in and checkout post to this site and redirect on to Google and Dodo, which form-action would
# also have to list. The static pages in public/ go without the policy (ApplicationController#render_static_page).
module ContentSecurity
  MAP_HOST = "https://tiles.openfreemap.org".freeze

  module_function

  # The folder of the maplibre-gl pin in config/importmap.rb, read on each request (the importmap is loaded by then,
  # and reloads with it in development). Nothing when there's no such pin.
  def maplibre_folder
    path = Rails.application.importmap.packages["maplibre-gl"]&.path.to_s
    Array(path[%r{\Ahttps://cdn\.jsdelivr\.net/npm/maplibre-gl@[^/]+/}])
  end

  # The map style's origin when MAP_STYLE_URL names another https or http host; a style that loads tiles from further
  # hosts needs them added here.
  def map_hosts(style_url = ENV["MAP_STYLE_URL"].to_s.strip)
    uri = URI.parse(style_url)
    [ MAP_HOST, (uri.origin if uri.is_a?(URI::HTTP) && uri.host) ].compact.uniq
  rescue URI::InvalidURIError
    [ MAP_HOST ]
  end
end

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri :self
    policy.object_src :none
    policy.frame_ancestors :self
    policy.script_src :self, -> { ContentSecurity.maplibre_folder }
    policy.style_src :self, "https://fonts.googleapis.com", -> { ContentSecurity.maplibre_folder }
    policy.font_src :self, "https://fonts.gstatic.com"
    policy.img_src :self, :https, :data, :blob
    policy.connect_src :self, -> { ContentSecurity.map_hosts }
    policy.worker_src :self, :blob, -> { ContentSecurity.maplibre_folder }
  end

  # One nonce per session, as Rails generates it: Turbo Drive keeps the first page's policy while it swaps pages in,
  # so the scripts and styles it adds later must carry the same nonce. A visitor's first page has no session yet
  # (Rails stores the CSRF token as the response ends), and an empty nonce would block the importmap, so that page
  # gets a random one. Turbo adds no script or style of its own after that first visit (its progress bar's <style>
  # is made at start), so the change of nonce on the second page is harmless.
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s.presence || SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]
end
