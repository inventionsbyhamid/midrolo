module Admin
  # Moving a podcast to another owner account (lane L4): for a show "managed by someone else" whose real owner wrote
  # in. The podcast is named by its page URL or slug, the new owner by their account email (they must have signed in
  # once). Claims::Transfer does the work; the change is logged.
  class ClaimTransfersController < BaseController
    def new; end

    def create
      podcast = Podcast.find_by_slug_or_redirect(slug_from(params[:podcast]))
      user = User.find_by("lower(email) = ?", params[:email].to_s.strip.downcase) if params[:email].present?
      return refuse("No podcast has that page or slug.") unless podcast
      return refuse("No account has that email. They need to sign in once first.") unless user

      previous = podcast.owner_show&.user
      Claims::Transfer.call(podcast: podcast, to: user)
      log_change("moved podcast #{podcast.id} from user #{previous&.id || 'none'} to user #{user.id}")
      redirect_to new_admin_claim_transfer_path, notice: "#{podcast.title} now belongs to #{user.email}.", status: :see_other
    end

    private

    # "https://midrolo.com/podcasts/the-ledger-abc123#rates", "/podcasts/the-ledger-abc123" or the slug itself.
    def slug_from(value)
      value.to_s.strip.split(/[?#]/).first.to_s.delete_suffix("/").split("/").last.to_s
    end

    def refuse(message)
      flash.now[:alert] = message
      render :new, status: :unprocessable_content
    end
  end
end
