module Users
  class OmniauthCallbacksController < Devise::OmniauthCallbacksController
    def google_oauth2 = sign_in_from_omniauth

    # Development only: the route exists solely when the developer strategy is configured.
    def developer = sign_in_from_omniauth

    def failure
      redirect_to new_user_session_path, alert: "Signing in didn't work. Please try again."
    end

    private

    # A sign in that made the account is the first one, so the welcome email goes then, and only then. Asked before
    # sign_in, whose sign in tracking saves the user again.
    def sign_in_from_omniauth
      user = User.from_omniauth(request.env["omniauth.auth"])
      first_sign_in = user.previously_new_record?
      sign_in(user, event: :authentication)
      UserMailer.welcome(user).deliver_later if first_sign_in
      redirect_to after_sign_in_path_for(user)
    rescue ActiveRecord::RecordInvalid
      # e.g. the email already belongs to a different account
      redirect_to new_user_session_path,
                  alert: "We couldn't sign you in with that Google account. Please contact support."
    end
  end
end
