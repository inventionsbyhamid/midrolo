module Brands
  # The brand's home (/brand, ApplicationController::BRAND_HOME): recent searches, saved shows, requests sent.
  class DashboardController < BaseController
    SEARCHES_SHOWN = 10
    SAVED_SHOWN = 6
    REQUESTS_SHOWN = 5

    def show
      current_user.working_as_brand!
      searches = brand_scoped(current_brand.fit_searches)
      @searches_count = searches.count
      @searches = searches.order(created_at: :desc, id: :desc).limit(SEARCHES_SHOWN).to_a
      FitSearch.fail_stale(@searches)
      @result_counts = FitResult.where(fit_search_id: @searches.map(&:id)).group(:fit_search_id).count
      saved = brand_scoped(current_brand.saved_podcasts)
      @saved_count = saved.count
      @saved = saved.includes(podcast: SavedPodcastsController::PODCAST_PRELOADS).order(created_at: :desc, id: :desc)
                    .limit(SAVED_SHOWN).to_a
      requests = current_brand.conversations
      requests = requests.where(started_by_id: current_user.id) unless current_brand_member.verified?
      @requests_count = requests.count
      @requests = requests.includes(podcast: SavedPodcastsController::PODCAST_PRELOADS).latest_first.limit(REQUESTS_SHOWN).to_a
    end
  end
end
