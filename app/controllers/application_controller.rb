class ApplicationController < ActionController::Base
  # Rate limits (spec §9a, §11; R69, R84) go through throttle: Rails' rate_limit, counted in RATE_LIMIT_STORE
  # (config/initializers/rate_limit_store.rb) and refused with the app's 429 (render_throttled). The global one is
  # here: every request, per IP, in one bucket across controllers. WebhooksController opts out (providers retry), and
  # Rails::HealthController (/up), Active Storage's controllers and Action Cable never reach it. The rest sit on the
  # controllers they guard: ReportsController and ShowsController (rate_limit_report_starts), PitchesController,
  # ShowSearchesController, VerificationsController, AccountsController and WaitlistEntriesController.
  # Per-user limits count the IP when signed out (user_or_ip). The IP is request.remote_ip, which never trusts a
  # header the client could have written itself (config/initializers/client_ip.rb). A limit binds to its action, so a
  # format (.html), doubled slashes or HEAD for GET reach the same count.
  #
  # Rails doesn't say how long a window has left, so the 429's Retry-After is always the whole window.
  def self.throttle(to:, within:, **options)
    rate_limit(to:, within:, store: RATE_LIMIT_STORE, with: -> { render_throttled(retry_after: within) }, **options)
  end

  throttle to: 60, within: 1.minute, by: -> { request.remote_ip }, scope: "global", unless: :exempt_from_global_rate_limit?

  # Starting a report, from ReportsController#create or a re-run in ShowsController#update: one bucket for both.
  def self.rate_limit_report_starts(**options)
    throttle to: 10, within: 1.hour, by: :user_or_ip, scope: "report_starts", **options
  end

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # Public media kits opt out (any_browser?): they are server-rendered and must open for any brand.
  allow_browser versions: :modern, unless: :any_browser?

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Sign-in is required per controller (before_action :authenticate_user!), never globally:
  # public pages and the development styleguide stay open.

  layout :layout_for_devise

  helper_method :current_plan

  def after_sign_in_path_for(_resource) = shows_path
  def after_sign_out_path_for(_scope) = "/"

  private

  # The signed-in user's plan (Entitlements), resolved once per request; the free plan when signed out.
  def current_plan = @current_plan ||= Entitlements.for(current_user)

  # Back to path with the plan's refusal (Entitlements::NotAllowed#details, as JSON-safe values), which the layout
  # shows as an upgrade prompt.
  def redirect_with_upgrade_prompt(path, error, **messages)
    redirect_to path, flash: messages.merge(upgrade: error.details.as_json)
  end

  # The app's friendly 429 (ThrottledResponse), for throttle's limits.
  def render_throttled(retry_after:)
    status, headers, body = ThrottledResponse.new(request, retry_after: retry_after).to_rack
    self.status = status
    self.content_type = headers.fetch("content-type")
    response.set_header("retry-after", headers.fetch("retry-after"))
    self.response_body = body
  end

  # Whom a per-user rate limit counts: the signed-in user, or the IP when signed out.
  def user_or_ip = current_user ? "user:#{current_user.id}" : "ip:#{request.remote_ip}"

  # True for provider webhooks, which retry and must never be refused.
  def exempt_from_global_rate_limit? = false

  def any_browser? = false

  def layout_for_devise
    devise_controller? ? "marketing" : "application"
  end
end
