# The demo data bin/setup loads (bin/rails demo:seed): the demo catalog (catalog:seed), an admin account to sign in as
# with the Dev sign in card, and the demo show (demo:setup). Only in development, and only while the taste provider and
# the podcast directory are both the Fakes (no QLOO_API_KEY, no Podcast Index keys), so it never calls Qloo or Podcast
# Index and never touches a real catalog. Every step is safe to run again.
module DemoSeed
  ADMIN_EMAIL = "demo-admin@midrolo.test".freeze
  ADMIN_NAME = "Demo Admin".freeze
  # Every podcast the Fake taste provider knows (Podcasts::Directories::Fake::CATALOG).
  CATALOG_SIZE = 16

  module_function

  # Why the demo data stays out, or nil when it goes in.
  def skip_reason(env: Rails.env)
    return "development only (this is #{env})" unless env.to_s == "development"
    return "QLOO_API_KEY is set, so the catalog would come from the live Qloo API" unless Taste::Provider.fake?
    return "the Podcast Index keys are set, so the catalog would come from the live directory" unless Podcasts::Directory.fake?

    nil
  end

  # The developer strategy's account for ADMIN_EMAIL (its uid is the email: AuthConfig::DEVELOPER_OPTIONS), made an
  # admin. The Dev sign in card with this email signs in to it.
  def admin!
    user = User.find_or_initialize_by(provider: "developer", uid: ADMIN_EMAIL)
    user.email ||= ADMIN_EMAIL
    user.name ||= ADMIN_NAME
    user.admin = true
    user.save!
    user
  end

  # Whether the Dev sign in card can offer ADMIN_EMAIL as an admin.
  def admin_ready? = User.exists?(provider: "developer", uid: ADMIN_EMAIL, admin: true)
end
