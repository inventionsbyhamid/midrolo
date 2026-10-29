# Podcaster or brand (review G-1, G-2). new is the choice a new account makes after its first sign in; update is that
# choice and the nav's side switch: it remembers the side (User#last_role, so sign in lands there next time) and opens
# its home. A brand side without a brand yet starts with "I'm a brand".
class SidesController < ApplicationController
  layout "application"
  before_action :authenticate_user!

  def new; end

  def update
    role = params[:role].to_s
    return redirect_to(welcome_path, status: :see_other) unless User::LAST_ROLES.include?(role)

    current_user.update!(last_role: role) unless current_user.last_role == role
    redirect_to role == "brand" ? brand_home : shows_path, status: :see_other
  end

  private

  def brand_home = current_user.brand_member? ? BRAND_HOME : brand_start_path
end
