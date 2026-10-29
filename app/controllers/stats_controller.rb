# The workspace's Stats screen (build spec section 11): invite Midrolo to the show's Spotify and Apple analytics, see
# where each connection stands and the numbers it verified, and the owner's own downloads per episode ("provided by
# the show") as the fallback. It works on an unclaimed workspace as a draft: invites can be set up, but numbers count
# and show on the podcast's page only for the owner. Scoped to the signed-in user's shows.
class StatsController < ApplicationController
  layout "app"
  before_action :authenticate_user!
  before_action :set_show
  throttle to: 20, within: 1.hour, only: :provided, by: -> { current_user.id }, name: "stats_provided"

  def show
    @podcast = @show.podcast
    @owner = owner?
    @claimed_elsewhere = @podcast.claimed? && !@owner
    @connections = visible_connections.index_by(&:provider)
    @readings = @podcast.stat_readings.to_a
  end

  # Saves the downloads per episode on the workspace, and for the owner also as the podcast's provided reading.
  def provided
    value = params[:downloads_per_episode].to_s.delete(",").strip
    downloads = value.presence && Integer(value, 10, exception: false)
    if value.present? && (downloads.nil? || downloads.negative? || downloads > 100_000_000)
      return redirect_to(show_stats_path(@show), alert: "Enter downloads per episode as a whole number.", status: :see_other)
    end

    @show.update!(downloads_per_episode: downloads)
    unless owner?
      return redirect_to(show_stats_path(@show), notice: "Saved to your workspace. Claim the show to put it on its page.",
                                                 status: :see_other)
    end

    @show.podcast.record_provided_downloads!(downloads)
    notice = downloads ? "Saved. Your page shows it as provided by the show." : "Removed from your page."
    redirect_to show_stats_path(@show), notice: notice, status: :see_other
  end

  private

  def set_show
    @show = current_user.shows.includes(:podcast).find_by!(public_id: params[:show_id])
  end

  # The podcast's owner is this workspace: it is verified (one owner per podcast).
  def owner? = @show.verified? && @show.podcast.claimed?

  # The owner sees every connection on the podcast (and may replace one another account left); any other workspace
  # sees only the user's own, never another account's platform show, error or buttons (review L10).
  def visible_connections
    connections = @podcast.stat_connections.where(provider: Stats::PLATFORMS.keys)
    @owner ? connections : connections.where(user_id: current_user.id)
  end
end
