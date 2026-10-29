module Brands
  # Fit searches: start one (FitSearch::Start queues FitSearchJob), watch its agent steps live, read the ranked shows.
  class SearchesController < BaseController
    # Bursts, on top of the member's searches a day (User::Brands::DAILY_SEARCHES).
    throttle to: 5, within: 10.minutes, only: :create, by: -> { current_user.id }, name: "fit_search_starts"

    INDEX_LIMIT = 50
    RESULT_PRELOADS = { podcast: [ :listing, { artwork_image: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } } } ] }.freeze

    def index
      @searches = visible_searches.includes(:brand).order(created_at: :desc, id: :desc).limit(INDEX_LIMIT).to_a
      @result_counts = FitResult.where(fit_search_id: @searches.map(&:id)).group(:fit_search_id).count
    end

    def new
      @search = FitSearch.new(query: current_brand.name, website: current_brand.domain,
                              categories: FitSearch::Categories.known(current_brand.categories))
    end

    def create
      search = FitSearch::Start.call(member: current_brand_member, attributes: search_params)
      redirect_to brand_search_path(search), status: :see_other
    rescue FitSearch::Start::Refused => e
      redirect_to new_brand_search_path, alert: e.message, status: :see_other
    rescue ActiveRecord::RecordInvalid => e
      @search = e.record
      flash.now[:alert] = "#{Copy.and_list(e.record.errors.full_messages)}."
      render :new, status: :unprocessable_content
    end

    def show
      @search = visible_searches.includes(:agent_steps).find_by!(public_id: params[:id])
      return unless @search.done?

      @results = @search.results.includes(RESULT_PRELOADS).to_a
      @saved_ids = current_brand.saved_podcasts.where(podcast_id: @results.map(&:podcast_id))
      @saved_ids = brand_scoped(@saved_ids).pluck(:podcast_id).to_set
    end

    private

    def search_params
      params.expect(fit_search: [ :query, :website, :budget, { categories: [] } ]).to_h
    end
  end
end
