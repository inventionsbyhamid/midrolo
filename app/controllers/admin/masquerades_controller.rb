# Masquerade (R150): an admin signs in as a user to see exactly what they see, then comes back. Devise's
# bypass_sign_in swaps the session's user without the sign-in callbacks, so the user's sign-in stats don't move and the
# session isn't renewed, which keeps the masquerader_id marker. create is admin-only (BaseController). destroy, the
# banner's button, can't be: current_user is then the other user. Its guard is the marker, which only create writes, in
# a signed and encrypted session cookie, and it signs back in only an account that is still an admin. While it lasts,
# ApplicationController#refuse_while_masquerading keeps the admin from deleting the account or touching its billing.
module Admin
  class MasqueradesController < BaseController
    skip_before_action :require_admin, :require_basic_auth, only: :destroy, raise: false

    def create
      user = User.find_by("lower(email) = ?", params[:email].to_s.strip.downcase)
      problem = refusal_for(user)
      return redirect_to(admin_users_path, alert: problem, status: :see_other) if problem

      admin = current_user
      log_change("masquerades as #{user.email} (user #{user.id})")
      bypass_sign_in(user, scope: :user)
      session[:masquerader_id] = admin.id
      redirect_to shows_path, notice: "You're viewing #{APP_NAME} as #{user.name.presence || user.email}.", status: :see_other
    end

    def destroy
      admin = User.find_by(id: session.delete(:masquerader_id), admin: true)
      raise ActionController::RoutingError, "Not Found" unless admin

      Rails.logger.info("[Admin] #{admin.email} (user #{admin.id}) stops masquerading as #{current_user&.email}")
      bypass_sign_in(admin, scope: :user)
      redirect_to admin_users_path, notice: "Back to your own account.", status: :see_other
    end

    private

    def refusal_for(user)
      if user.nil? || user.samples_owner? then "No user has that email."
      elsif user == current_user then "That's you."
      elsif user.admin? then "Admins can't view the app as another admin."
      end
    end
  end
end
