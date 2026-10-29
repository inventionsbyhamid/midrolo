# The sign-in page says what you were doing (UX review G-3), from where Devise or a page stored your way back
# (session["user_return_to"]), instead of Devise's red "You need to sign in or sign up before continuing."
module SignInContextHelper
  # "Sign in to claim Shipping Soon", "Sign in to request a spot on Shipping Soon", "Sign in to find podcasts for your
  # brand"... or nil when there's no stored place or it isn't one of these.
  def sign_in_context(return_to = session["user_return_to"])
    uri = URI.parse(return_to.to_s)
    path = uri.path.to_s
    params = Rack::Utils.parse_query(uri.query.to_s)
    case path
    when %r{\A/podcasts/([^/]+)/claim\b} then sign_in_context_for("claim", $1)
    when "/conversations/new" then sign_in_context_for("request a spot on", params["podcast"])
    when %r{\A/podcasts/([^/]+)\z} then sign_in_context_for("see who listens to", $1)
    when %r{\A/brand(/|\z)} then "Sign in to find podcasts for your brand"
    when %r{\A/(shows|inbox|account)(/|\z)} then "Sign in to your shows and requests"
    end
  rescue URI::InvalidURIError
    nil
  end

  # True for Devise's own "sign in first" alert, which the sign-in page leaves out when it has the context line.
  def sign_in_unauthenticated_alert?
    flash[:alert].present? && flash[:alert] == I18n.t("devise.failure.unauthenticated")
  end

  private

  def sign_in_context_for(action, slug)
    title = Podcast.where(slug: slug.to_s).where.not(status: "removed").pick(:title) if slug.present?
    title ? "Sign in to #{action} #{title}" : nil
  end
end
