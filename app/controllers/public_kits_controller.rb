# A published media kit at /k/:slug. Unknown slugs, unpublished kits and unverified shows are 404 for everyone.
class PublicKitsController < ApplicationController
  layout "kit"

  def show
    @show = Show.find_by!(slug: params[:slug].to_s)
    @kit = @show.media_kit
    raise ActiveRecord::RecordNotFound unless @show.public_kit?

    @content = MediaKit::Content.new(@kit)
    @kit.record_view(viewer: current_user, user_agent: request.user_agent)
  end

  private

  # A brand may open the kit from a pitch email in whatever browser their company gives them.
  def any_browser? = true
end
