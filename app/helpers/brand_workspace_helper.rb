# The brand workspace's views (lane L6): fit search results, proof lines, prices and the nav. Every method starts with
# brand_ (build spec section 10); BrandHelper is the logo's.
module BrandWorkspaceHelper
  PRICE_FIT_BADGES = {
    "within" => [ "Within your budget", :success ], "stretch" => [ "A little over budget", :warning ],
    "over" => [ "Over budget", :danger ], "ask" => [ "No rate card yet", :neutral ]
  }.freeze
  SEARCH_STATUS = { "queued" => [ "Queued", :accent ], "running" => [ "Searching", :accent ],
                    "done" => [ "Ready", :success ], "failed" => [ "Failed", :danger ] }.freeze
  PROOF_RELATIONS = { "competitor" => "a competitor", "complementary" => "a brand your customers also buy",
                      "category" => "a brand in your category" }.freeze

  def brand_nav_links
    links = [ [ "Brand", brand_root_path ], [ "Find podcasts", new_brand_search_path ], [ "Saved", brand_saved_podcasts_path ] ]
    links << [ "Your shows", shows_path ] if current_user&.shows&.exists?
    links << [ "Account", account_path ]
  end

  def brand_search_status_badge(search)
    text, tone = SEARCH_STATUS.fetch(search.status)
    ui_badge(text, tone: tone)
  end

  def brand_price_fit_badge(price_fit)
    text, tone = PRICE_FIT_BADGES[price_fit.to_s]
    ui_badge(text, tone: tone) if text
  end

  # "From $400 per episode", from the show's published rate card; nil without one.
  def brand_price_text(podcast)
    cents = podcast.min_price_cents
    "From #{number_to_currency(cents / 100.0, precision: 0)} per episode" if cents
  end

  # "2,140 per episode" from the show's best downloads number (verified Spotify and Apple plays, or the show's own).
  def brand_downloads_text(podcast)
    value = podcast.downloads_per_episode
    "#{number_with_delimiter(value)} per episode" if value
  end

  # "Open for Nov, Dec and Jan" from a show's published listing.
  def brand_open_months_text(podcast)
    return nil unless podcast.open_to_sponsors?

    months = Array(podcast.listing&.open_months).filter_map do |month|
      Date.strptime(month.to_s, "%Y-%m").strftime("%b")
    rescue Date::Error
      nil
    end
    months.any? ? "Open for #{Copy.and_list(months.first(6))}" : "Open to sponsors"
  end

  # One line of proof: "Mercury, a competitor, sponsored 4 episodes".
  def brand_proof_line(row)
    episodes = pluralize(row["episodes"].to_i, "episode")
    return "You sponsored #{episodes} here" if row["relation"] == "you"

    "#{row['brand']}, #{PROOF_RELATIONS.fetch(row['relation'], 'a brand like yours')}, sponsored #{episodes}"
  end

  # Where a podcast's public page is (lane L3's /podcasts/:slug).
  def brand_podcast_href(podcast, anchor: nil)
    path = respond_to?(:podcast_path) ? podcast_path(podcast) : "/podcasts/#{ERB::Util.url_encode(podcast.to_param)}"
    anchor ? "#{path}##{anchor}" : path
  end

  def brand_summary_bullets(search) = search.summary.to_s.lines.map(&:strip).compact_blank

  # The score's four parts as "Taste 38 of 50", for the breakdown under a result.
  def brand_score_parts(result)
    points = result.proof.is_a?(Hash) ? result.proof["points"].to_h : {}
    FitSearch::Scoring::WEIGHTS.map { |part, weight| [ part.to_s.capitalize, points[part.to_s].to_i, weight ] }
  end
end
