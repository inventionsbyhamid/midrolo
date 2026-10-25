require "rails_helper"

RSpec.describe "Billing portal" do
  let(:user) { create(:user) }

  it "requires sign-in" do
    with_billing_env("BILLING_MODE" => "test") { post "/billing_portal" }
    expect(response).to redirect_to("/users/sign_in")
  end

  it "redirects to the provider's portal for the user's subscription" do
    with_billing_env("BILLING_MODE" => "test") do
      create(:subscription, user: user, provider: "fake", provider_customer_id: "fake_cus_9")
      sign_in user

      post "/billing_portal"

      expect(response).to redirect_to("http://www.example.com/fake_portal?customer_id=fake_cus_9")
    end
  end

  it "opens the portal in any billing mode, the waitlist included (R73)" do
    with_billing_env do
      create(:subscription, user: user, provider: "fake", provider_customer_id: "fake_cus_9")
      sign_in user

      post "/billing_portal"

      expect(response).to redirect_to("http://www.example.com/fake_portal?customer_id=fake_cus_9")
    end
  end

  it "returns 404 without a subscription that has a customer id" do
    create(:subscription, user: user, provider: "fake", provider_customer_id: nil)
    sign_in user

    with_billing_env { post "/billing_portal" }

    expect(response).to have_http_status(:not_found)
  end

  it "sends the user back with an alert when the subscription's provider isn't configured here" do
    allow(Rails.logger).to receive(:error)
    create(:subscription, user: user, provider: "dodo", provider_customer_id: "cus_1")
    sign_in user

    with_billing_env { post "/billing_portal" }

    expect(response).to redirect_to(account_path)
    expect(Rails.logger).to have_received(:error).with(/DODO_API_KEY/)
  end

  it "sends the user back with an alert when the provider fails" do
    env = { "BILLING_MODE" => "live", "DODO_API_KEY" => "live_key_not_real", "DODO_ENVIRONMENT" => "live_mode" }
    with_billing_env(env) do
      allow(Rails.logger).to receive(:error)
      stub_request(:post, %r{https://live\.dodopayments\.com/customers/cus_1/customer-portal/session}).to_return(status: 403, body: "{}")
      create(:subscription, user: user, provider: "dodo", provider_customer_id: "cus_1")
      sign_in user

      post "/billing_portal"

      expect(response).to redirect_to(account_path)
      expect(flash[:alert]).to eq("We couldn't open billing just now. Please try again.")
    end
  end
end
