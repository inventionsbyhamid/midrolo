# /admin/stat_connections: the stats connections queue (build spec section 11). Pending invites come first, oldest
# first, so the admin knows which invite emails to accept for the stats account; then the connections that need a
# look (mismatch, failed, disconnected) and the active ones. Check now syncs one at once.
#
# Inside module Admin, Stats is Admin::Stats, so the stats services are written ::Stats.
module Admin
  class StatConnectionsController < BaseController
    LIMIT = 200
    ORDER = %w[pending_invite mismatch failed disconnected active].freeze

    def index
      scope = StatConnection.includes(:podcast, :user)
      @groups = ORDER.index_with do |status|
        order = status == "pending_invite" ? { created_at: :asc } : { updated_at: :desc }
        scope.where(status: status).order(order).limit(LIMIT).to_a
      end
      @counts = StatConnection.group(:status).count
      @sessions = ServiceSession.all.index_by(&:platform)
    end

    def check
      connection = StatConnection.find(params[:id])
      ::Stats::SyncJob.perform_later(connection.id)
      log_change("asked for a sync of stats connection #{connection.id}")
      redirect_to admin_stat_connections_path, notice: "Sync queued for #{connection.podcast.title}.", status: :see_other
    end
  end
end
