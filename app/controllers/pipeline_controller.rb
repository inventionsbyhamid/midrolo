# Every brand the podcaster is working, across all their shows, grouped by stage (R46), with a CSV export on
# plans that include it.
class PipelineController < ApplicationController
  include PipelineGate

  CSV_UPSELL = "CSV export is part of the Pro plan.".freeze

  layout "app"
  before_action :authenticate_user!
  before_action :require_pipeline

  def index
    @matches = Pipeline::Matches.for(current_user).to_a
    respond_to do |format|
      format.html { @csv_export = plan.csv_export? }
      format.csv { export }
    end
  end

  private

  def export
    return redirect_to(pricing_path, notice: CSV_UPSELL, status: :see_other) unless plan.csv_export?

    send_data Pipeline::Csv.generate(@matches), type: :csv, filename: "midrolo-pipeline-#{Date.current.iso8601}.csv"
  end
end
