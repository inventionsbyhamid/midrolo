# A workspace's Spotify and Apple connections (build spec section 11). create is "I've invited Midrolo": it records the
# platform's show id from the pasted link as a pending invite, which Stats::SyncDueJob polls until the first fetch
# works. check asks for a sync now, and destroy disconnects (the numbers from that platform come off the page).
# Scoped to the signed-in user's shows; a connection is theirs to change when they made it or own the podcast.
class StatConnectionsController < ApplicationController
  layout "app"
  before_action :authenticate_user!
  before_action :set_show
  before_action :set_connection, only: %i[check destroy]
  # Each check runs the platform helper, and each invite starts 15-minute polling: cap how fast either can be pressed.
  throttle to: 10, within: 1.hour, only: :create, by: -> { current_user.id }, name: "stats_invites"
  throttle to: 6, within: 1.hour, only: :check, by: -> { current_user.id }, name: "stats_checks"

  CLAIMED_ELSEWHERE = "Another account owns this show on Midrolo, so its stats connect there.".freeze

  def create
    provider = params[:provider].to_s
    return redirect_to(show_stats_path(@show), alert: "Choose Spotify or Apple Podcasts.", status: :see_other) unless Stats.platform?(provider)
    return redirect_to(show_stats_path(@show), alert: CLAIMED_ELSEWHERE, status: :see_other) if claimed_elsewhere?

    show_id = Stats.show_id_from(provider, params[:show_link])
    return bad_link_redirect(provider) unless show_id

    existing = @podcast.stat_connections.find_by(provider: provider)
    if existing && !replaceable?(existing)
      return redirect_to(show_stats_path(@show), alert: "Someone else connected this show's #{Stats.platform_name(provider)}. " \
                                                        "Claim the show to connect it yourself.", status: :see_other)
    end

    connection = StatConnection.transaction do
      existing&.destroy!
      StatConnection.release_unowned!(provider: provider, external_id: show_id, except_podcast_id: @podcast.id) if owner?
      @podcast.stat_connections.create!(provider: provider, external_id: show_id, show: @show, user: current_user,
                                        status: "pending_invite")
    end
    Stats::SyncJob.perform_later(connection.id)
    redirect_to show_stats_path(@show, anchor: provider), notice: invited_notice(provider), status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    redirect_to show_stats_path(@show, anchor: provider), alert: Copy.and_list(e.record.errors.full_messages), status: :see_other
  rescue ActiveRecord::RecordNotUnique
    # Another page took the platform show at the same moment, or a double click made this connection already.
    taken = StatConnection.where(provider: provider, external_id: show_id, status: StatConnection::HOLDING_STATUSES)
                          .where.not(podcast_id: @podcast.id).exists?
    alert = taken ? StatConnection::TAKEN_MESSAGE : "That connection was just made. Have a look below."
    redirect_to show_stats_path(@show), alert: alert, status: :see_other
  end

  def check
    Stats::SyncJob.perform_later(@connection.id)
    redirect_to show_stats_path(@show, anchor: @connection.provider),
                notice: "Checking now. Refresh in a minute to see what we found.", status: :see_other
  end

  def destroy
    provider = @connection.provider
    counted = owner? || @connection.activated_at.present?
    @connection.destroy!
    # Only a connection that could have saved numbers takes numbers with it.
    @podcast.remove_stat_source!(provider) if counted
    redirect_to show_stats_path(@show, anchor: provider), status: :see_other,
                notice: "Disconnected. To end Midrolo's access too, remove #{Stats.invite_email(provider)} from your " \
                        "team in #{Stats.service_name(provider)}."
  end

  private

  def set_show
    @show = current_user.shows.includes(:podcast).find_by!(public_id: params[:show_id])
    @podcast = @show.podcast
  end

  # Only this podcast's connections that this user may change: their own, or any once they own the podcast.
  def set_connection
    @connection = @podcast.stat_connections.find(params[:id])
    raise ActiveRecord::RecordNotFound unless replaceable?(@connection)
  end

  def owner? = @show.verified? && @podcast.claimed?

  def claimed_elsewhere? = @podcast.claimed? && !owner?

  def replaceable?(connection) = connection.user_id == current_user.id || owner?

  def invited_notice(provider)
    if owner?
      "Thanks. We'll check every 15 minutes until the invite is accepted, then your #{Stats.platform_name(provider)} numbers appear here."
    else
      "Saved. Claim the show, and its #{Stats.platform_name(provider)} numbers count once the invite is accepted."
    end
  end

  # The card itself says what's wrong, under the field, with what was typed still in it (review ST-3).
  def bad_link_redirect(provider)
    flash[:stats_bad_link] = { "provider" => provider, "message" => bad_link(provider),
                               "link" => params[:show_link].to_s.strip.first(300) }
    redirect_to show_stats_path(@show, anchor: provider), status: :see_other
  end

  def bad_link(provider)
    if provider == "spotify"
      "Paste your show's Spotify link, like https://open.spotify.com/show/... (in Spotify, Share, then Copy link to show)."
    else
      "Paste your show's Apple Podcasts link, like https://podcasts.apple.com/us/podcast/your-show/id123456789."
    end
  end
end
