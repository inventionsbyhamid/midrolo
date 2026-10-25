class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # Public media kits opt out (any_browser?): they are server-rendered and must open for any brand.
  allow_browser versions: :modern, unless: :any_browser?

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Sign-in is required per controller (before_action :authenticate_user!), never globally:
  # public pages and the development styleguide stay open.

  layout :layout_for_devise

  helper_method :current_plan

  def after_sign_in_path_for(_resource) = shows_path
  def after_sign_out_path_for(_scope) = "/"

  private

  # The signed-in user's plan (Entitlements), resolved once per request; the free plan when signed out.
  def current_plan = @current_plan ||= Entitlements.for(current_user)

  # Back to path with the plan's refusal (Entitlements::NotAllowed#details, as JSON-safe values), which the layout
  # shows as an upgrade prompt.
  def redirect_with_upgrade_prompt(path, error, **messages)
    redirect_to path, flash: messages.merge(upgrade: error.details.as_json)
  end

  # The app's friendly 429 (ThrottledResponse) for a rate_limit's with:. Rails doesn't say how long its window has
  # left, so Retry-After is the whole window.
  def render_throttled(retry_after:)
    status, headers, body = ThrottledResponse.new(request, retry_after: retry_after).to_rack
    self.status = status
    self.content_type = headers.fetch("content-type")
    response.set_header("retry-after", headers.fetch("retry-after"))
    self.response_body = body
  end

  def any_browser? = false

  def layout_for_devise
    devise_controller? ? "marketing" : "application"
  end
end
