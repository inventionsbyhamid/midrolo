# Show: claiming a podcast through its workspace.
# Lane L4 adds its methods here, and only here (build spec section 10), so lanes don't edit the same model file.
#
# A workspace is a draft until its user proves the show is theirs (verify!, in show.rb): drafts can build a listing and
# preview it, and only the owner show's listing is published on the podcast page.
module Show::Claiming
  extend ActiveSupport::Concern

  # Where this workspace stands with its podcast: :claimed (this is the owner show), :managed_elsewhere (another
  # account's show owns the podcast) or :draft. Reads the podcast's claimed_at, so a list needs only the podcast
  # preloaded.
  def claim_status
    return :claimed if verified?

    podcast.claimed? ? :managed_elsewhere : :draft
  end

  # Brings the podcast's directory columns (open to sponsors, lowest rate, downloads) in line with this show's listing
  # when it's the owner show. A draft's listing isn't public, so it changes nothing.
  def sync_listing!
    podcast.refresh_listing! if verified?
  end

  # The user's email is the feed's owner address, so signing in with it proves the show is theirs (Listen Notes'
  # instant claim). Only for a Google sign in, which has checked the address (and the developer sign in, which exists
  # only in development and test).
  def owner_email_matches_user?(address = owner_email)
    feed = ShowVerification.normalize_address(address)
    feed.present? && feed == ShowVerification.normalize_address(user.email) && user_email_checked?
  end

  private

  def user_email_checked?
    user.provider == "google_oauth2" || (Rails.env.local? && user.provider == "developer")
  end
end
