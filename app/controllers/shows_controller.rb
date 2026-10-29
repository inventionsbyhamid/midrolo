class ShowsController < ApplicationController
  layout "app"
  # A re-run (update with rerun=<kind>) starts a report, so it counts with ReportsController#create.
  rate_limit_report_starts only: :update, if: -> { Report::KINDS.include?(params[:rerun].to_s) }
  before_action :authenticate_user!
  before_action :set_show, only: %i[show edit update]

  def index
    @shows = current_user.shows.order(:created_at).includes(:latest_report)
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
      render_new(status: :unprocessable_content, error: Copy.and_list(show.errors.full_messages))
    end
  rescue ActiveRecord::RecordNotUnique
    # A concurrent double-submit won the race: send them to the show that now exists.
    duplicate = existing_duplicate(result&.attributes || {})
    duplicate ? redirect_to(show_path(duplicate), notice: "You've already added this show.") : raise
  rescue Podcasts::Directory::Unavailable
    render_new(status: :unprocessable_content, error: ShowSearchesController::UNAVAILABLE)
  end

  def show; end

  def edit
    @onboarding = params[:onboarding].present?
  end

  # With rerun=<kind> (the needs-input form on a report, R41) it also starts that report and opens it. A re-run
  # needs at least one comparable show, or it would end needs_input again.
  def update
    rerun = params[:rerun].to_s
    if Report::KINDS.include?(rerun) && submitted_comparable_shows.empty?
      return redirect_to(rerun_return_path, alert: "Add at least one show your listeners also like.")
    end

    if @show.update(show_params)
      return rerun_report(rerun) if Report::KINDS.include?(rerun)

      redirect_to show_path(@show), notice: "Details saved."
    else
      @onboarding = params[:onboarding].present?
      render :edit, status: :unprocessable_content
    end
  end

  private

  def rerun_report(kind)
    report = Report.start!(show: @show, kind: kind, user: current_user)
    redirect_to show_report_path(@show, report)
  rescue Entitlements::NotAllowed => e
    redirect_with_upgrade_prompt(show_path(@show), e, notice: "Details saved.")
  end

  def submitted_comparable_shows
    Array(params.dig(:show, :hints, :comparable_shows)).map { |name| name.to_s.strip }.reject(&:empty?)
  end

  # Back to the needs-input report the form came from, when it is this show's.
  def rerun_return_path
    report = @show.reports.find_by(public_id: params[:report_id])
    report ? show_report_path(@show, report) : show_path(@show)
  end

  def set_show
    @show = current_user.shows.find_by!(public_id: params[:id])
  end

  def show_params
    params.expect(show: [ :downloads_per_episode, :country, :contact_email,
                          { hints: { comparable_shows: [], topics: [] } } ])
  end

  # A downgraded user keeps every show they have; they just can't add more.
  def at_limit?
    current_user.shows.count >= current_plan.max_shows
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
