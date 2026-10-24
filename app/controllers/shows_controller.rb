class ShowsController < ApplicationController
  layout "app"
  before_action :authenticate_user!
  before_action :set_show, only: %i[show edit update]

  def index
    @shows = current_user.shows.order(:created_at)
    redirect_to new_show_path if @shows.empty?
  end

  def new
    @at_limit = at_limit?
  end

  def create
    duplicate = existing_duplicate
    return redirect_to(show_path(duplicate), notice: "You've already added this show.") if duplicate
    return render_new(status: :unprocessable_content, at_limit: true) if at_limit?

    result = ShowLookup.call(directory_id: params[:directory_id], feed_url: params[:feed_url])
    return render_new(status: :unprocessable_content, error: result.error) unless result.ok?

    duplicate = existing_duplicate(result.attributes)
    return redirect_to(show_path(duplicate), notice: "You've already added this show.") if duplicate

    show = current_user.shows.new(result.attributes)
    if show.save
      RefreshShowFeedJob.perform_later(show.id)
      redirect_to edit_show_path(show, onboarding: 1)
    else
      render_new(status: :unprocessable_content, error: show.errors.full_messages.to_sentence)
    end
  rescue Podcasts::Directory::Unavailable
    render_new(status: :unprocessable_content, error: ShowSearchesController::UNAVAILABLE)
  end

  def show; end

  def edit
    @onboarding = params[:onboarding].present?
  end

  def update
    if @show.update(show_params)
      redirect_to show_path(@show), notice: "Details saved."
    else
      @onboarding = params[:onboarding].present?
      render :edit, status: :unprocessable_content
    end
  end

  private

  def set_show
    @show = current_user.shows.find(params[:id])
  end

  def show_params
    params.expect(show: [ :downloads_per_episode, :country, :contact_email,
                          { hints: { comparable_shows: [], topics: [] } } ])
  end

  def at_limit?
    current_user.shows.count >= Entitlements.for(current_user).max_shows
  end

  # A show this user already added, matched by what they sent (or by the looked-up attributes).
  def existing_duplicate(attributes = {})
    shows = current_user.shows
    directory_id = attributes[:directory_id] || params[:directory_id].presence
    feed_url = attributes[:feed_url] || params[:feed_url].to_s.strip.presence
    (directory_id && shows.find_by(directory_id: directory_id)) || (feed_url && shows.find_by(feed_url: feed_url))
  end

  def render_new(status:, error: nil, at_limit: false)
    @error = error
    @at_limit = at_limit
    @feed_url = params[:feed_url]
    render :new, status: status
  end
end
