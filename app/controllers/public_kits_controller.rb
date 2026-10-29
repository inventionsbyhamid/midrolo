# /k/:slug, the old public media kit (lane L4): a 301 to the podcast page's Rates section, /podcasts/:slug#rates,
# where the published listing now lives, so links already shared keep working and build on one URL. The slug may be
# the podcast's or an earlier one (podcast_redirects); unknown slugs are a 404. The share image at /k/:slug/og.png
# stays (ShareImagesController).
class PublicKitsController < ApplicationController
  def show
    podcast = Podcast.find_by_slug_or_redirect(params[:slug])
    raise ActiveRecord::RecordNotFound if podcast.nil? || podcast.removed?

    redirect_to helpers.listing_podcast_path(podcast, anchor: "rates"), status: :moved_permanently
  end

  private

  # A brand may open the link from a pitch email in whatever browser their company gives them.
  def any_browser? = true
end
