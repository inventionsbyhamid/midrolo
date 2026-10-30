# GET /shows/search?q= : results for the Turbo Frame search_results on the add-a-show page.
class ShowSearchesController < ApplicationController
  layout "app"
  # Search as you type. Before sign-in is required, so a signed-out client is counted by IP.
  throttle to: 20, within: 1.minute, by: :user_or_ip
  before_action :authenticate_user!

  UNAVAILABLE = "Search is unavailable right now. Try again in a minute, or paste your RSS feed URL.".freeze

  CATALOG_LIMIT = 5
  RESULT_LIMIT = 10

  # Midrolo's own catalog first (it knows shows Podcast Index doesn't), then the directory without repeats.
  def show
    @query = params[:q].to_s.strip.first(100)
    return if @query.blank?

    catalog = Podcast.listed.search_catalog(@query).for_cards.limit(CATALOG_LIMIT).to_a
    @results = (catalog + directory_results(catalog)).first(RESULT_LIMIT)
    @unavailable = true if @directory_down && catalog.empty?
  end

  private

  # Directory hits that aren't already a catalog hit (same directory_id, or the same feed once normalized).
  def directory_results(catalog)
    ids = catalog.filter_map(&:directory_id)
    feeds = catalog.map { |podcast| Podcast.normalize_feed_url(podcast.feed_url) }
    Podcasts::Directory.current.search(@query, limit: RESULT_LIMIT).reject do |info|
      ids.include?(info.directory_id) || feeds.include?(Podcast.normalize_feed_url(info.feed_url))
    end
  rescue Podcasts::Directory::Unavailable
    @directory_down = true
    []
  end
end
