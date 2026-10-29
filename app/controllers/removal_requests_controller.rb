# "Remove this page" (spec L3, plan 9): anyone can ask for any podcast's page to come down. The owner (signed in, with
# the verified workspace) removes it at once; anyone else's request waits for an admin (Admin::RemovalRequestsController),
# answered within 7 days. Podcast#remove! does the removing.
class RemovalRequestsController < ApplicationController
  include CatalogPage

  throttle to: 5, within: 1.hour, by: :user_or_ip, scope: "removal_requests", only: :create

  RECEIVED = "Thanks. We'll review your request and reply within 7 days.".freeze
  REMOVED = "The page is gone. It won't come back, even if the show is searched for again.".freeze
  EMAIL_NEEDED = "Add an email address so we can reply.".freeze

  before_action :set_podcast

  def new
    noindex!
    @request_form = RemovalRequest.new(podcast: @podcast)
  end

  def create
    @request_form = @podcast.removal_requests.new(removal_params)
    if owner?
      RemovalRequest.transaction do
        @request_form.update!(status: "approved", email: @request_form.email.presence || current_user.email)
        @podcast.remove!
      end
      redirect_to podcasts_path, notice: REMOVED, status: :see_other
    elsif @request_form.email.blank?
      @request_form.errors.add(:email, EMAIL_NEEDED)
      render_form
    elsif @request_form.save
      redirect_to podcast_path(@podcast), notice: RECEIVED, status: :see_other
    else
      render_form
    end
  end

  private

  def set_podcast
    @podcast = find_podcast { |slug| new_podcast_removal_path(slug) } or return
    render_removed if @podcast.removed?
  end

  # Signed in as the user whose workspace is the podcast's verified owner.
  def owner? = current_user.present? && Show.where(podcast_id: @podcast.id, user_id: current_user.id).where.not(verified_at: nil).exists?
  helper_method :owner?

  def removal_params
    params.fetch(:removal_request, {}).permit(:email, :reason).to_h.transform_values { |value| value.to_s.strip.first(2_000) }
  end

  def render_form
    noindex!
    render :new, status: :unprocessable_content
  end
end
