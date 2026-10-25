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

  # Back to path with the plan's refusal (Entitlements::NotAllowed), which the layout shows as an upgrade prompt.
  def redirect_with_upgrade_prompt(path, error, kind:, **messages)
    redirect_to path, flash: messages.merge(upgrade: { "reason" => error.reason.to_s, "kind" => kind.to_s })
  end

  def any_browser? = false

  def layout_for_devise
    devise_controller? ? "marketing" : "application"
  end
end
