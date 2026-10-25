# GET /shows/search?q= : results for the Turbo Frame search_results on the add-a-show page.
class ShowSearchesController < ApplicationController
  layout "app"
  # Search as you type. Before sign-in is required, so a signed-out client is counted by IP.
  rate_limit to: 20, within: 1.minute, by: :user_or_ip, store: RATE_LIMIT_STORE,
             with: -> { render_throttled(retry_after: 1.minute) }
  before_action :authenticate_user!

  UNAVAILABLE = "Search is unavailable right now. Try again in a minute, or paste your RSS feed URL.".freeze

  def show
    @query = params[:q].to_s.strip.first(100)
    @results = @query.present? ? Podcasts::Directory.current.search(@query, limit: 10) : nil
  rescue Podcasts::Directory::Unavailable
    @unavailable = true
  end
end
