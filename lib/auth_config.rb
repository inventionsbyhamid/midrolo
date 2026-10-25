# Which OmniAuth strategies are on. Google is the real one. The developer strategy (a name and an email, no password)
# exists only for local development without Google keys. Our sign in page offers it as a small "Dev sign in" card
# (R101) whose form posts straight to the developer callback, so OmniAuth's own unstyled form at /users/auth/developer
# is never shown. Rails checks the form's CSRF token when the callback reaches Users::OmniauthCallbacksController.
module AuthConfig
  # What the developer strategy reads from the callback's params: the uid is the email.
  DEVELOPER_OPTIONS = { fields: %i[name email], uid_field: :email }.freeze
  DEVELOPER_CALLBACK_PATH = "/users/auth/developer/callback".freeze

  module_function

  def developer_strategy?(env: Rails.env, client_id: ENV["GOOGLE_CLIENT_ID"])
    env.to_s == "development" && client_id.blank?
  end
end
