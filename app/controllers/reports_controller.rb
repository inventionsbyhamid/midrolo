class ReportsController < ApplicationController
  layout "app"
  # Before sign-in is required, so a signed-out client is counted by IP.
  rate_limit_report_starts only: :create
  before_action :authenticate_user!
  before_action :set_show

  def create
    kind = params[:kind].to_s
    return redirect_to(show_path(@show), alert: "Choose a Snapshot or a full report.") unless Report::KINDS.include?(kind)

    report = Report.start!(show: @show, kind: kind, user: current_user)
    redirect_to show_report_path(@show, report)
  rescue Entitlements::NotAllowed => e
    redirect_with_upgrade_prompt(show_path(@show), e)
  end

  # Opening a finished report, including the refresh a live page makes when its run ends, means the owner saw it.
  def show
    @report = @show.reports.includes(:agent_steps, :sponsor_matches).find_by!(public_id: params[:id])
    @report.mark_viewed!
  end

  private

  def set_show
    @show = current_user.shows.find_by!(public_id: params[:show_id])
  end
end
