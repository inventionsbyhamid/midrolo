# Billing provider webhooks, POST /webhooks/:provider (spec §9a). The raw body's signature is checked first (400 when
# it fails), then the event is stored once by its id and applied by ProcessBillingEventJob, so the provider gets its
# 200 straight away. An event we don't act on is stored and settled all the same, never a 500.
# Machine traffic: no CSRF token (for this controller only), no browser check, and no per-IP rate limit, since a
# provider retries a refused delivery.
class WebhooksController < ApplicationController
  skip_forgery_protection

  def create
    provider = Billing::Provider.for(params[:provider])
    return head :not_found unless provider

    raw_body = request.raw_post
    event = provider.parse(raw_body, id: provider.verify!(raw_body, request.headers))
    billing_event = BillingEvent.record!(event)
    ProcessBillingEventJob.perform_later(billing_event.id) unless billing_event.processed?
    head :ok
  rescue Billing::InvalidSignature => e
    Rails.logger.warn("[Billing] #{provider.name} webhook rejected: #{e.message}")
    head :bad_request
  rescue Billing::MissingCredentials => e
    # Not a 400: the provider retries a failed delivery, so events wait for the secret to be set.
    Rails.logger.error("[Billing] #{provider.name} webhook can't be verified: #{e.message}")
    head :service_unavailable
  end

  private

  def any_browser? = true
  def exempt_from_global_rate_limit? = true
end
