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

  # The brand side's nav (NavigationHelper#nav_brand_links); the side switch leads back to Your shows.
  def brand_nav_links = nav_brand_links(current_user)

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

  # "2,140 plays per episode" (verified Spotify and Apple plays) or "1,000 to 2,500 downloads per episode" (the show's
  # own, as a range when the owner chose ranges): Podcast#public_downloads, so only for a claimed show.
  def brand_downloads_text(podcast) = podcast.public_downloads&.text

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
  def brand_podcast_href(podcast, anchor: nil) = podcast_path(podcast, anchor: anchor)

  def brand_summary_bullets(search) = search.summary.to_s.lines.map(&:strip).compact_blank

  # The result groups, in rank order (FitSearch::Scoring::TIERS): [key, heading, note, tiers].
  RESULT_GROUPS = [
    [ "ready", "Ready to book", "Claimed by the show, open to sponsors and within your budget.", %w[ready] ],
    [ "joined", "On #{APP_NAME}, worth a word", "Claimed by the show, but over your budget, without rates yet or not taking sponsors right now.", %w[open claimed] ],
    [ "unclaimed", "Good fits that haven't joined yet", "Your request waits until the show claims its page. We never email shows that haven't joined.", %w[unclaimed] ],
    [ "dormant", "On a break", "No new episode in months. Ask only if you can wait.", %w[dormant] ]
  ].freeze
  STEP_TITLES = { "find_brand" => "Found your brand on Qloo", "qloo_podcasts" => "Podcasts its customers love",
                  "category_scores" => "Shows in your categories", "proof" => "Who already sponsors them",
                  "price_trust" => "Price and trust", "rank" => "Ranked for you", "summary" => "Summary" }.freeze
  # A brand whose proof shows up on at least this share of the results (and on 3 or more) is said once, above them
  # (review BR-8).
  COMMON_PROOF_SHARE = 0.25
  COMMON_PROOF_MIN_SHOWS = 3
  # Tiers whose group heading already says what the card's note would.
  TIERS_WITHOUT_NOTE = %w[ready unclaimed].freeze
  # Results a group lists before "Show N more" (the ready group lists all).
  RESULTS_SHOWN = 10

  # A result's tier (FitSearch::Scoring.tier), read from what the run saved; older results get it from the podcast.
  def brand_result_tier(result)
    result.proof["tier"].presence || FitSearch::Scoring.tier(
      claimed: result.podcast.claimed?, open: result.podcast.open_to_sponsors?, price_fit: result.price_fit,
      dormant: result.podcast.status == "dormant"
    )
  end

  # [[key, heading, note, results]] for the groups that have results, in rank order.
  def brand_result_groups(results)
    by_tier = results.group_by { |result| brand_result_tier(result) }
    RESULT_GROUPS.filter_map do |key, heading, note, tiers|
      list = tiers.flat_map { |tier| by_tier.fetch(tier, []) }.sort_by(&:position)
      [ key, heading, note, list ] if list.any?
    end
  end

  # Why a show sits where it does, in a few words for its card; nil where the group's heading says it already.
  def brand_tier_note(result)
    return nil if TIERS_WITHOUT_NOTE.include?(brand_result_tier(result))

    brand_tier_reason(result)
  end

  def brand_tier_reason(result)
    podcast = result.podcast
    case brand_result_tier(result)
    when "ready" then "Ready to book"
    when "open" then result.price_fit == "ask" ? "Open to sponsors, no rates yet" : "Open to sponsors, over your budget"
    when "claimed" then "On #{APP_NAME}, not taking sponsors right now"
    when "dormant"
      podcast.last_published_at ? "No new episode in #{distance_of_time_in_words(podcast.last_published_at, Time.current)}" : "No new episodes lately"
    else "Hasn't joined #{APP_NAME} yet"
    end
  end

  # "Strong fit" (FitSearch::Scoring.fit_word) beside the number.
  def brand_fit_word(result) = FitSearch::Scoring.fit_word(result.score)

  # Proof rows that show up on most results (a big brand in the category): [[row, shows]], said once above the list
  # so each card keeps only its own proof.
  def brand_common_proof(results)
    floor = [ COMMON_PROOF_MIN_SHOWS, (results.size * COMMON_PROOF_SHARE).ceil ].max
    rows = results.flat_map { |result| Array(result.proof["brands"]).uniq { |row| row["brand"] } }
    rows.group_by { |row| row["brand"] }.filter_map { |_, list| [ list.first, list.size ] if list.size >= floor }
  end

  # One result's proof rows, without the brands already said above the list.
  def brand_own_proof(result, common)
    names = common.map { |row, _| row["brand"] }
    Array(result.proof["brands"]).reject { |row| names.include?(row["brand"]) }
  end

  # "HelloFresh, a brand in your category, sponsored 8 of these shows".
  def brand_common_proof_line(row, shows)
    who = row["relation"] == "you" ? "You" : "#{row['brand']}, #{PROOF_RELATIONS.fetch(row['relation'], 'a brand like yours')},"
    "#{who} sponsored #{shows} of these shows" # shows is at least COMMON_PROOF_MIN_SHOWS
  end

  # The step's short title for the "How we found these" panel; a find_brand step that warned says Qloo didn't know it.
  def brand_step_title(step)
    return "Qloo doesn't know this brand yet" if step.tool == "find_brand" && step.warning?

    STEP_TITLES.fetch(step.tool.to_s) { step.label.to_s.delete_suffix("…") }
  end

  # True when the search found nothing because Qloo didn't know the brand and nobody picked a category (review BR-9).
  def brand_search_needs_categories?(search)
    search.qloo_brand_entity_id.blank? && Array(search.categories).empty?
  end

  # The score's four parts as "Taste 38 of 50", for the breakdown under a result.
  def brand_score_parts(result)
    points = result.proof.is_a?(Hash) ? result.proof["points"].to_h : {}
    FitSearch::Scoring::WEIGHTS.map { |part, weight| [ part.to_s.capitalize, points[part.to_s].to_i, weight ] }
  end
end
