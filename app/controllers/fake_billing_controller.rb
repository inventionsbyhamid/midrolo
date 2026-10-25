# The Fake billing provider's pages (Billing::Providers::Fake), in development and test only: the routes exist only
# when Rails.env.local?, and production never offers the Fake. Its checkout completes a test payment the way a real
# one does: a Standard-Webhooks-signed event goes through the real /webhooks/fake route, WebhooksController checks it
# and enqueues ProcessBillingEventJob, and the buyer lands on the success page. Its portal is a stand-in page.
class FakeBillingController < ApplicationController
  layout "app"
  before_action :authenticate_user!
  before_action :set_price, only: %i[checkout pay]

  def checkout; end

  def pay
    fake = Billing::Providers::Fake.new
    body = fake.test_payment(user: current_user, price: @price)
    status = deliver_webhook(body, fake.signed_headers(body))
    if status == 200
      redirect_to billing_success_path(status: @price.interval == :once ? "succeeded" : "active")
    else
      redirect_to account_path, alert: "The test payment's webhook was refused (HTTP #{status})."
    end
  end

  def portal; end

  private

  def set_price
    @price = Billing.price(params[:price_key])
    head :not_found unless @price
  end

  # Through the app's router, not its whole middleware stack: a nested pass through the executor middleware would end
  # this request's own execution state. Returns the HTTP status.
  def deliver_webhook(body, headers)
    env = Rack::MockRequest.env_for(
      webhooks_path(provider: Billing::Providers::Fake::NAME), method: "POST", input: body,
      "CONTENT_TYPE" => "application/json", "HTTP_HOST" => request.host_with_port,
      **headers.transform_keys { |name| "HTTP_#{name.upcase.tr('-', '_')}" }
    )
    status, = Rails.application.routes.call(Rails.application.env_config.merge(env))
    status
  end
end
