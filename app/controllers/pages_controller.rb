# The public pages (Task 19, R78): the landing page (for everyone; signed-in visitors get their own links in the
# header), pricing, about, privacy, terms and robots.txt. Nothing here needs a session. The sitemap is SitemapsController's.
#
# The landing page speaks to both sides of the marketplace (lane L9). What it shows is real: the first sample report's
# top matches, shows from the directory, the demo show's listing, and the catalog's own counts. None of it is made up,
# and a part with nothing real to show is left out.
class PagesController < ApplicationController
  layout "marketing"

  # Shows from the directory on the brand side of the landing page.
  SHOWCASE_SIZE = 3
  # The catalog's counts are worth saying once there's a real directory behind them.
  CATALOG_FACTS_FROM = 50
  LANDING_CACHE = 1.hour

  def home
    @samples = Samples.reports
    @hero_sample = @samples.first
    @hero_matches = @hero_sample ? @hero_sample.sponsor_matches.first(3) : []
    @showcase = showcase
    @showcase_sponsors = SponsorMention.where(podcast_id: @showcase.map(&:id)).group(:podcast_id).distinct.count(:brand_id)
    @demo = Podcast.for_page.demo.where(status: Podcast::LISTED_STATUSES).first
    @catalog_facts = catalog_facts
    @explainer = YoutubeVideo.explainer
  end

  def pricing; end

  # "Get my free Snapshot" for a visitor: remember that they came to add a show, then sign in. After sign in they
  # land on /shows/new, skipping the "podcaster or brand" choice the link has already made.
  def start
    return redirect_to(new_show_path) if user_signed_in?

    store_location_for(:user, new_show_path)
    redirect_to new_user_session_path
  end
  def about; end
  def privacy; end
  def terms; end

  def robots; end

  private

  # Landing and legal pages must open for anyone, in any browser (a link in an email, a crawler).
  def any_browser? = true

  # A few indexable shows from the directory, the ones a brand would look at first: open to sponsors, then claimed,
  # then the most sponsors found, then the newest episode. The ids are cached for an hour; the cards load fresh.
  def showcase
    ids = Rails.cache.fetch("landing/showcase_ids", expires_in: LANDING_CACHE) do
      sponsors = SponsorMention.select("podcast_id, COUNT(DISTINCT brand_id) AS brands").group(:podcast_id)
      Podcast.listed.not_demo.where(indexable: true)
             .joins("LEFT JOIN (#{sponsors.to_sql}) sponsors ON sponsors.podcast_id = podcasts.id")
             .order(Arel.sql("podcasts.open_to_sponsors DESC, (podcasts.claimed_at IS NOT NULL) DESC, " \
                             "COALESCE(sponsors.brands, 0) DESC, podcasts.last_published_at DESC NULLS LAST, podcasts.id"))
             .limit(SHOWCASE_SIZE).pluck(:id)
    end
    Podcast.for_cards.listed.where(id: ids).in_order_of(:id, ids).to_a
  end

  # { podcasts:, sponsor_reads:, brands: } from the catalog, or nil while it's too small to be worth saying.
  def catalog_facts
    facts = Rails.cache.fetch("landing/catalog_facts", expires_in: LANDING_CACHE) do
      { podcasts: Podcast.listed.not_demo.count, sponsor_reads: SponsorMention.count,
        brands: SponsorMention.distinct.count(:brand_id) }
    end
    facts if facts[:podcasts] >= CATALOG_FACTS_FROM
  end
end
