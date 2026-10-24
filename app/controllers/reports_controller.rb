class ReportsController < ApplicationController
  layout "app"
  before_action :authenticate_user!
  before_action :set_show

  def create
    kind = params[:kind].to_s
    return redirect_to(show_path(@show), alert: "Choose a Snapshot or a full report.") unless Report::KINDS.include?(kind)

    report = Report.start!(show: @show, kind: kind, user: current_user)
    redirect_to show_report_path(@show, report)
  rescue Entitlements::NotAllowed
    redirect_to show_path(@show), alert: "You can't start that report on your current plan. See your account for options."
  end

  def show
    @report = @show.reports.includes(:agent_steps, :sponsor_matches).find(params[:id])
  end

  private

  def set_show
    @show = current_user.shows.find(params[:show_id])
  end
end
