# Public sample reports (spec §5.1, R78): the full agent report for anyone, read-only (no pitch, pipeline or owner
# controls), labelled as not affiliated with the show. An unknown or unfinished sample is a 404.
class SamplesController < ApplicationController
  layout "marketing"

  def index
    @samples = Samples.reports
    @match_counts = Samples.match_counts(@samples)
  end

  def show
    @report = Samples.find!(params[:slug])
    @show = @report.show
  end

  private

  def any_browser? = true
end
