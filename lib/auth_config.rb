# Which OmniAuth strategies are on. Google is the real one. The developer strategy
# (a name-and-email form) exists only for local development without Google keys.
module AuthConfig
  module_function

  def developer_strategy?(env: Rails.env, client_id: ENV["GOOGLE_CLIENT_ID"])
    env.to_s == "development" && client_id.blank?
  end
end
