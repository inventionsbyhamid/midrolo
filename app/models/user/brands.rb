# User: the brand side of an account.
# Lane L6 adds its methods here, and only here (build spec section 10), so lanes don't edit the same model file.
module User::Brands
  extend ActiveSupport::Concern

  # Requests a brand member may send a day (lane L7 counts them): a verified work email earns the higher limit.
  DAILY_REQUESTS = { verified: 25, unverified: 3 }.freeze
  # Fit searches a member may start a day. Each one makes up to 10 Qloo calls, so unverified members get fewer.
  DAILY_SEARCHES = { verified: 20, unverified: 5 }.freeze

  # The membership the brand workspace works in: the one with membership_id (BrandMember#id, kept in the session when
  # the user picks a brand), else the newest. nil for a user who isn't on a brand yet.
  def brand_member(membership_id = nil)
    members = brand_members.includes(:brand).order(created_at: :desc, id: :desc)
    (membership_id && members.find_by(id: membership_id)) || members.first
  end

  def brand_member? = brand_members.exists?

  # Marks the account as working on the brand side, so sign in lands on the brand dashboard next time.
  def working_as_brand!
    update!(last_role: "brand") unless last_role == "brand"
  end

  def brand_daily_request_limit(member = brand_member)
    DAILY_REQUESTS.fetch(member&.verified? ? :verified : :unverified)
  end

  def brand_daily_search_limit(member = brand_member)
    DAILY_SEARCHES.fetch(member&.verified? ? :verified : :unverified)
  end

  # Fit searches started in the last 24 hours (index user_id, created_at).
  def brand_searches_today = fit_searches.where(created_at: 24.hours.ago..).count
end
