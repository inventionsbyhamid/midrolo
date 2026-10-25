class ApplicationController < ActionController::Base
  # Rate limits (spec §9a, §11; R69, R84) are Rails' rate_limit, counted in RATE_LIMIT_STORE
  # (config/initializers/rate_limit_store.rb) and refused with the app's 429 (render_throttled):
  # - every request, here: 60 a minute per IP, in one bucket across controllers. WebhooksController opts out
  #   (providers retry). Rails::HealthController (/up) and Active Storage's controllers don't inherit this class, and
  #   Action Cable isn't a controller, so none of them is ever counted.
  # - starting a report (ReportsController#create, or a re-run in ShowsController#update): 10 an hour per user.
  # - PitchesController#create: 30 an hour per user. ShowSearchesController: 20 a minute per user.
  # - VerificationsController#create: 5 emailed codes an hour per show, besides 10 tries a minute per user.
  # - AccountsController#judge_code: 5 an hour per user and 5 an hour per IP.
  # Per-user limits count the IP when signed out (user_or_ip). The IP is request.remote_ip, which never trusts a
  # Forwarded header the client sent (config/initializers/client_ip.rb). A limit binds to its action, so a format
  # (.html), doubled slashes or HEAD for GET reach the same count.
  rate_limit to: 60, within: 1.minute, by: -> { request.remote_ip }, scope: "global", store: RATE_LIMIT_STORE,
             unless: :exempt_from_global_rate_limit?, with: -> { render_throttled(retry_after: 1.minute) }

  # Starting a report, from ReportsController#create or a re-run in ShowsController#update: one bucket for both.
  def self.rate_limit_report_starts(**options)
    rate_limit to: 10, within: 1.hour, by: :user_or_ip, scope: "report_starts", store: RATE_LIMIT_STORE,
               with: -> { render_throttled(retry_after: 1.hour) }, **options
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

  # The app's friendly 429 (ThrottledResponse) for a rate_limit's with:. Rails doesn't say how long its window has
  # left, so Retry-After is the whole window.
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
