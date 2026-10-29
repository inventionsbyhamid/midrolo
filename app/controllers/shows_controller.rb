class ShowsController < ApplicationController
  ALREADY_ADDED = "You've already added this show.".freeze

  layout "app"
  # A re-run (update with rerun=<kind>) starts a report, so it counts with ReportsController#create.
  rate_limit_report_starts only: :update, if: -> { Report::KINDS.include?(params[:rerun].to_s) }
  before_action :authenticate_user!
  before_action :set_show, only: %i[show edit update]

  def index
    @shows = current_user.shows.order(:created_at)
                         .includes(:latest_report, :media_kit, podcast: [ :stat_connections, { artwork_image: { file_attachment: :blob } } ])
    redirect_to new_show_path if @shows.empty?
  end

  def new
    @at_limit = at_limit?
    @onboarding = current_user.shows.none?
  end

  # Adding a show is starting a workspace for its podcast: the podcast is found (or made, from the directory or the
  # feed) through Podcast.find_or_create_from_lookup!, and its feed is read at once (Catalog::IngestPodcastJob).
  def create
    duplicate = existing_show(submitted_podcast)
    return redirect_to(show_path(duplicate), notice: ALREADY_ADDED) if duplicate
    return render_new(status: :unprocessable_content, at_limit: true) if at_limit?

    result = ShowLookup.call(directory_id: params[:directory_id], feed_url: params[:feed_url])
    return render_new(status: :unprocessable_content, error: result.error) unless result.ok?

    podcast = Podcast.find_or_create_from_lookup!(result.attributes.merge(source: "claim"))
    duplicate = existing_show(podcast)
    return redirect_to(show_path(duplicate), notice: ALREADY_ADDED) if duplicate

    show = current_user.shows.new(podcast: podcast)
    show.save!
    podcast.ingest_later(priority: :high)
    redirect_to edit_show_path(show, onboarding: 1)
  rescue ActiveRecord::RecordInvalid => e
    render_new(status: :unprocessable_content, error: Copy.and_list(e.record.errors.full_messages))
  rescue ActiveRecord::RecordNotUnique
    # A concurrent double-submit won the race: send them to the show that now exists.
    duplicate = existing_show(podcast)
    duplicate ? redirect_to(show_path(duplicate), notice: ALREADY_ADDED) : raise
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
      # The owner's typed downloads are the podcast's "provided by the show" reading (build spec section 10).
      @show.podcast.record_provided_downloads!(@show.downloads_per_episode) if @show.verified? && @show.saved_change_to_downloads_per_episode?
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
    @show = current_user.shows.includes(:podcast).find_by!(public_id: params[:id])
  end

  def show_params
    params.expect(show: [ :downloads_per_episode, :country, :contact_email,
                          { hints: { comparable_shows: [], topics: [] } } ])
  end

  # A downgraded user keeps every show they have; they just can't add more.
  def at_limit?
    current_user.shows.count >= current_plan.max_shows
  end

  # The podcast the form names, when the catalog has it already: by directory id or feed URL, before any lookup.
  def submitted_podcast
    directory_id = params[:directory_id].to_s.strip.presence
    feed_url = params[:feed_url].to_s.strip.presence
    (directory_id && Podcast.for_directory_id(directory_id)) || (feed_url && Podcast.find_by(feed_url: feed_url))
  end

  # This user's workspace for the podcast, if they have one.
  def existing_show(podcast)
    current_user.shows.find_by(podcast_id: podcast.id) if podcast&.persisted?
  end

  def render_new(status:, error: nil, at_limit: false)
    @error = error
    @at_limit = at_limit
    @onboarding = current_user.shows.none?
    @feed_url = params[:feed_url]
    render :new, status: status
  end
end
