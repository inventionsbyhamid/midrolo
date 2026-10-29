# GET /admin/removal_requests: "Remove this page" requests from anyone but the owner, oldest pending first, to approve
# (Podcast#remove!) or reject within 7 days. The owner's own requests remove at once and show here as approved.
module Admin
  class RemovalRequestsController < BaseController
    LIMIT = 100

    def index
      response.headers["X-Robots-Tag"] = "noindex, nofollow"
      @pending = RemovalRequest.pending.includes(:podcast).order(:created_at).limit(LIMIT)
      @decided = RemovalRequest.where.not(status: "pending").includes(:podcast).order(updated_at: :desc).limit(20)
    end

    def update
      request_row = RemovalRequest.includes(:podcast).find(params[:id])
      decision = params[:decision].to_s.presence_in(%w[approved rejected]) || raise(ActionController::BadRequest)
      RemovalRequest.transaction do
        request_row.update!(status: decision)
        request_row.podcast.remove! if decision == "approved" && !request_row.podcast.removed?
      end
      log_change("#{decision} removal request #{request_row.id} for podcast #{request_row.podcast_id}")
      redirect_to admin_removal_requests_path, notice: "Request #{decision}.", status: :see_other
    end
  end
end
