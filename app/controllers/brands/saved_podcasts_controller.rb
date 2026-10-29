module Brands
  # A brand's saved shows (its shortlist). show answers the Save button's lazy frame on a podcast page
  # (podcasts/_save), so the button's state never rides on that page's HTTP cache; a user with no brand gets a link
  # to start one. :id is the podcast's public id.
  class SavedPodcastsController < BaseController
    skip_before_action :require_brand_member, only: :show
    throttle to: 60, within: 1.minute, only: %i[create destroy], by: -> { current_user.id }, name: "brand_saves"

    PODCAST_PRELOADS = [ :listing, { artwork_image: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } } } ].freeze
    INDEX_LIMIT = 200

    def index
      @saved = brand_scoped(current_brand.saved_podcasts).includes(podcast: PODCAST_PRELOADS)
                 .order(created_at: :desc, id: :desc).limit(INDEX_LIMIT).to_a
    end

    def show
      @podcast = find_podcast
      @saved = current_brand_member ? saved_scope.exists?(podcast: @podcast) : nil
      render partial: "brands/saved_podcasts/frame", locals: { podcast: @podcast, saved: @saved }
    end

    def create
      @podcast = find_podcast
      current_brand.saved_podcasts.create_with(user: current_user).find_or_create_by!(podcast: @podcast)
      respond_with_button(saved: true, notice: "Saved to your shortlist.")
    rescue ActiveRecord::RecordNotUnique
      respond_with_button(saved: true, notice: "Saved to your shortlist.")
    end

    def destroy
      @podcast = find_podcast
      saved_scope.where(podcast: @podcast).destroy_all
      respond_with_button(saved: false, notice: "Removed from your shortlist.")
    end

    private

    def find_podcast = Podcast.where.not(status: "removed").find_by!(public_id: params[:id] || params[:podcast_id])

    def saved_scope = brand_scoped(current_brand.saved_podcasts)

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
