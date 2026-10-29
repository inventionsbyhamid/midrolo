# /admin/stat_connections: the stats connections queue (build spec section 11). Pending invites come first, oldest
# first, so the admin knows which invite emails to accept for the stats account; then the connections that need a
# look (mismatch, failed, disconnected) and the active ones. Check now syncs one at once; a connection held for review
# (another podcast has the same name) gets Approve and Reject.
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

    # The admin checked by hand that this platform show is this podcast (another catalog podcast has the same name):
    # its numbers may count from the next sync, queued now.
    def approve
      connection = StatConnection.find(params[:id])
      connection.update!(approved_at: Time.current)
      ::Stats::SyncJob.perform_later(connection.id)
      log_change("approved stats connection #{connection.id} (#{connection.provider} #{connection.external_id}) for podcast #{connection.podcast_id}")
      redirect_to admin_stat_connections_path, notice: "Approved. Syncing #{connection.podcast.title} now.", status: :see_other
    end

    # The admin checked by hand and the platform show isn't this podcast: disconnect it, with its numbers
    # (::Stats::RejectConnection). Only a connection still held for review.
    def reject
      connection = StatConnection.find(params[:id])
      unless ::Stats::RejectConnection.call(connection)
        return redirect_to admin_stat_connections_path, alert: "That connection isn't waiting for review any more.", status: :see_other
      end

      log_change("rejected stats connection #{connection.id} (#{connection.provider} #{connection.external_id}) for podcast #{connection.podcast_id}")
      redirect_to admin_stat_connections_path, status: :see_other,
                  notice: "Rejected. #{connection.podcast.title}'s #{::Stats.platform_name(connection.provider)} connection is disconnected."
    end
  end
end
