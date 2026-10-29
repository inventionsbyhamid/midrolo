# Public sample reports (spec §5.1, R78): the full agent report for anyone, read-only (no pitch, pipeline or owner
# controls), labelled as not affiliated with the show, and each sample's media kit. An unknown or unfinished sample is a
# 404.
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

  # The sample's media kit (R152): the kit page a published show gets, built from the sample report's show and
  # labelled like the report. It leaves out the contact section (the show isn't ours to offer) and isn't indexed,
  # so a search for the show never finds a kit it didn't make. Nothing is saved: the kit is built, never stored.
  def kit
    @report = Samples.find!(params[:slug])
    @show = @report.show
    @kit = @show.media_kit || @show.build_media_kit
    @content = MediaKit::Content.new(@kit)
    response.headers["X-Robots-Tag"] = "noindex"
    render layout: "kit"
  end

  private

  def any_browser? = true
end
