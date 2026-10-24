# GET /shows/search?q= : results for the Turbo Frame search_results on the add-a-show page.
class ShowSearchesController < ApplicationController
  layout "app"
  before_action :authenticate_user!

  UNAVAILABLE = "Search is unavailable right now. Try again in a minute, or paste your RSS feed URL.".freeze

  def show
    @query = params[:q].to_s.strip.first(100)
    @results = @query.present? ? Podcasts::Directory.current.search(@query, limit: 10) : nil
  rescue Podcasts::Directory::Unavailable
    @unavailable = true
  end
end
