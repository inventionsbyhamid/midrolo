# A published media kit at /k/:slug, the podcast's slug. An earlier slug of the podcast (podcast_redirects) 301s to the
# current one. Unknown slugs, unpublished kits and podcasts without an owner show are 404 for everyone. (Lane L4 turns
# this page into a 301 to the podcast page's rates.)
class PublicKitsController < ApplicationController
  layout "kit"

  def show
    podcast = Podcast.find_by_slug_or_redirect(params[:slug]) || raise(ActiveRecord::RecordNotFound)
    return redirect_to(public_kit_path(podcast.slug), status: :moved_permanently) if podcast.slug != params[:slug].to_s

    @show = podcast.owner_show
    raise ActiveRecord::RecordNotFound unless @show&.public_kit?

    @kit = @show.media_kit
    @content = MediaKit::Content.new(@kit)
    @kit.record_view(viewer: current_user, user_agent: request.user_agent, ip: request.remote_ip)
  end

  private

  # A brand may open the kit from a pitch email in whatever browser their company gives them.
  def any_browser? = true
end
