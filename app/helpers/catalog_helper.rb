# The catalog's view helpers (lane L1; build spec section 10: one module per lane, catalog_ names).
module CatalogHelper
  STATUS_TONES = { "pending" => :neutral, "active" => :success, "dormant" => :warning, "failed" => :danger,
                   "removed" => :neutral }.freeze
  # What a feed error code (podcasts.last_error, Catalog::FeedFetcher and Catalog::Ingest) means, for the admin.
  ERROR_LABELS = {
    "feed_blocked" => "Feed URL not allowed (not http(s) on 80 or 443, or an internal address)",
    "feed_timeout" => "Feed took too long",
    "feed_unreachable" => "Feed host unreachable",
    "feed_tls_error" => "Feed host's certificate failed",
    "feed_not_found" => "Feed not found (404)",
    "feed_gone" => "Feed gone (410)",
    "feed_forbidden" => "Feed refused us (401 or 403)",
    "feed_rate_limited" => "Feed host asked us to slow down (429)",
    "feed_server_error" => "Feed host error (5xx)",
    "feed_redirect_loop" => "Feed redirects in a loop",
    "feed_too_many_redirects" => "Feed redirects too many times",
    "feed_too_large" => "Feed over 15 MB with no whole episode",
    "feed_empty" => "Feed is empty",
    "feed_unparseable" => "Not an RSS feed",
    "feed_unreadable" => "Feed couldn't be read",
    "feed_blocked_by_show" => "The show asks not to be listed",
    "suppressed" => "Removed from the catalog",
    "ingest_error" => "Ingest failed (see the error log)"
  }.freeze

  def catalog_status_badge(status)
    ui_badge(status.to_s.humanize, tone: STATUS_TONES.fetch(status.to_s, :neutral))
  end

  def catalog_error_label(code)
    code = code.to_s
    ERROR_LABELS[code] || (code.start_with?("feed_http_") ? "Feed answered HTTP #{code.delete_prefix('feed_http_')}" : code.humanize)
  end

  # "Libsyn", or nil for no or an unknown provider.
  def catalog_hosting_name(podcast) = Catalog::Detection.provider_name(podcast.hosting_provider)

  # ["OP3", "Podtrac"]: the measurement prefixes the podcast's feed carries.
  def catalog_measurement_names(podcast) = Array(podcast.measurement).filter_map { |key| Catalog::Detection.vendor_name(key) }
end
