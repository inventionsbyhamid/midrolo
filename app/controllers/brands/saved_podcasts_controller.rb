module Brands
  # A brand's saved shows (its shortlist). show answers the Save button's lazy frame on a podcast page
  # (podcasts/_save), so the button's state never rides on that page's HTTP cache; a user with no brand gets a link
  # to start one. :id is the podcast's public id.
  class SavedPodcastsController < BaseController
    skip_before_action :require_brand_member, only: :show
    throttle to: 60, within: 1.minute, only: %i[create destroy], by: -> { current_user.id }, name: "brand_saves"

    PODCAST_PRELOADS = [ :listing, { artwork_image: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } } } ].freeze
    INDEX_LIMIT = 200
    SAVED = "Saved to your shortlist.".freeze
    # The brand keeps one row per show. An unverified member doesn't see a colleague's (brand_scoped), so their Save
    # can't claim it saved anything (review L7).
    COLLEAGUE_SAVED = "Someone at your brand already saved this show. Verify your work email to see your brand's list.".freeze

    # Each saved show with its latest fit from the brand's searches and the brand's latest request to it (review
    # BR-11): two queries for the whole list.
    def index
      @saved = brand_scoped(current_brand.saved_podcasts).includes(podcast: PODCAST_PRELOADS)
                 .order(created_at: :desc, id: :desc).limit(INDEX_LIMIT).to_a
      ids = @saved.map(&:podcast_id)
      @fits = FitResult.where(fit_search_id: visible_searches.where(brand_id: current_brand.id).select(:id), podcast_id: ids)
                       .order(created_at: :desc, id: :desc).to_a.uniq(&:podcast_id).index_by(&:podcast_id)
      requests = current_brand.conversations.where(podcast_id: ids)
      requests = requests.where(started_by_id: current_user.id) unless current_brand_member.verified?
      @requests = requests.order(created_at: :desc, id: :desc).to_a.uniq(&:podcast_id).index_by(&:podcast_id)
    end

    def show
      @podcast = find_podcast
      @saved = current_brand_member ? saved_scope.exists?(podcast: @podcast) : nil
      render partial: "brands/saved_podcasts/frame", locals: { podcast: @podcast, saved: @saved }
    end

    def create
      @podcast = find_podcast
      row = save_row
      if row.user_id == current_user.id || current_brand_member.verified?
        respond_with_button(saved: true, notice: SAVED)
      else
        respond_with_button(saved: :colleague, notice: COLLEAGUE_SAVED)
      end
    end

    def destroy
      @podcast = find_podcast
      saved_scope.where(podcast: @podcast).destroy_all
      respond_with_button(saved: false, notice: "Removed from your shortlist.")
    end

    private

    def find_podcast = Podcast.where.not(status: "removed").find_by!(public_id: params[:id] || params[:podcast_id])

    def saved_scope = brand_scoped(current_brand.saved_podcasts)

    # The brand's row for the show: this member's new one, or the one already there (a colleague's, maybe).
    def save_row
      current_brand.saved_podcasts.create_with(user: current_user).find_or_create_by!(podcast: @podcast)
    rescue ActiveRecord::RecordNotUnique
      current_brand.saved_podcasts.find_by!(podcast: @podcast)
    end

    def respond_with_button(saved:, notice:)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(helpers.dom_id(@podcast, :save), partial: "brands/saved_podcasts/frame",
                                                                                      locals: { podcast: @podcast, saved: saved })
        end
        format.html { redirect_back_or_to brand_saved_podcasts_path, notice: notice, status: :see_other }
      end
    end
  end
end
