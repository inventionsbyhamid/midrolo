module Users
  class OmniauthCallbacksController < Devise::OmniauthCallbacksController
    def google_oauth2 = sign_in_from_omniauth

    # Development only: the route exists solely when the developer strategy is configured.
    def developer = sign_in_from_omniauth

    def failure
      redirect_to new_user_session_path, alert: "Sign-in didn't work. Please try again."
    end

    private

    def sign_in_from_omniauth
      user = User.from_omniauth(request.env["omniauth.auth"])
      sign_in(user, event: :authentication)
      redirect_to after_sign_in_path_for(user)
    end
  end
end
