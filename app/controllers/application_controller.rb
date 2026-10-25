class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # Public media kits opt out (any_browser?): they are server-rendered and must open for any brand.
  allow_browser versions: :modern, unless: :any_browser?

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Sign-in is required per controller (before_action :authenticate_user!), never globally:
  # public pages and the development styleguide stay open.

  layout :layout_for_devise

  def after_sign_in_path_for(_resource) = shows_path
  def after_sign_out_path_for(_scope) = "/"

  private

  def any_browser? = false

  def layout_for_devise
    devise_controller? ? "marketing" : "application"
  end
end
