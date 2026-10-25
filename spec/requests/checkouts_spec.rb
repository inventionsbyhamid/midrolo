require "rails_helper"

RSpec.describe "Checkouts" do
  let(:user) { create(:user) }

  context "in waitlist mode (the default)" do
    around { |example| with_billing_env { example.run } }

    it "returns 404 to signed-in users and visitors alike" do
      post "/checkouts", params: { price_key: "creator_monthly" }
      expect(response).to have_http_status(:not_found)

      sign_in user
      post "/checkouts", params: { price_key: "creator_monthly" }
      expect(response).to have_http_status(:not_found)
    end

    it "lets a judge or an admin try checkout against the provider in test mode (the Fake here)" do
      sign_in create(:user, judge: true)
      post "/checkouts", params: { price_key: "pro_monthly" }
      expect(response).to redirect_to(%r{\Ahttp://www\.example\.com/fake_checkout\?price_key=pro_monthly})

      sign_in create(:user, admin: true)
      post "/checkouts", params: { price_key: "sprint" }
      expect(response).to redirect_to(%r{/fake_checkout\?price_key=sprint})
    end

    it "returns 404 to a judge when the provider takes live payments" do
      with_billing_env("DODO_API_KEY" => "live_key_not_real", "DODO_ENVIRONMENT" => "live_mode") do
        sign_in create(:user, judge: true)
        post "/checkouts", params: { price_key: "pro_monthly" }
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  context "in test mode with the Fake provider" do
    around { |example| with_billing_env("BILLING_MODE" => "test") { example.run } }

    it "requires sign-in" do
      post "/checkouts", params: { price_key: "creator_monthly" }
      expect(response).to redirect_to("/users/sign_in")
    end

    it "redirects to the fake checkout URL containing the price_key" do
      sign_in user
      post "/checkouts", params: { price_key: "creator_monthly" }

      expect(response).to redirect_to("http://www.example.com/fake_checkout?price_key=creator_monthly&user_id=#{user.id}")
    end

    it "takes the redirect target from the provider only, never from params" do
      sign_in user
      post "/checkouts", params: { price_key: "creator_monthly", return_url: "https://evil.example", redirect_to: "https://evil.example",
                                   url: "https://evil.example" }

      expect(response.location).to start_with("http://www.example.com/fake_checkout?")
      expect(response.location).not_to include("evil")
    end

    it "refuses a price key that isn't in plans.yml" do
      sign_in user
      post "/checkouts", params: { price_key: "notify" }
      expect(response).to redirect_to(pricing_path)
      expect(flash[:alert]).to eq("That plan isn't available.")

      post "/checkouts", params: { price_key: "https://evil.example" }
      expect(response).to redirect_to(pricing_path)
    end

    it "sends a subscriber to Manage billing instead of a second subscription" do
      create(:subscription, user: user, plan: "creator")
      sign_in user

      %w[creator_monthly pro_yearly sprint].each do |price_key|
        post "/checkouts", params: { price_key: price_key }
        expect(response).to redirect_to(account_path)
        expect(flash[:alert]).to eq("You're already on Creator — use Manage billing to change plans.")
      end
    end

    it "lets a sprint be bought again to extend it, but no recurring plan during it" do
      create(:subscription, user: user, plan: "sprint", current_period_end: 10.days.from_now)
      sign_in user

      post "/checkouts", params: { price_key: "sprint" }
      expect(response).to redirect_to(%r{/fake_checkout\?price_key=sprint})

      post "/checkouts", params: { price_key: "pro_monthly" }
      expect(response).to redirect_to(account_path)
      expect(flash[:alert]).to eq("You're already on Sprint — use Manage billing to change plans.")
    end

    it "lets a lapsed subscriber buy again" do
      create(:subscription, user: user, status: "canceled", current_period_end: 1.day.ago)
      sign_in user

      post "/checkouts", params: { price_key: "creator_monthly" }
      expect(response).to redirect_to(%r{/fake_checkout\?price_key=creator_monthly})
    end

    it "thanks the buyer on return, since the webhook may lag" do
      sign_in user
      get "/billing/success", params: { subscription_id: "sub_1", status: "active" }

      expect(response).to redirect_to(account_path)
      follow_redirect!
      expect(response.body).to include("Thanks — your plan updates in a few seconds.")
    end

    it "says so when the provider reports the checkout failed" do
      sign_in user
      get "/billing/success", params: { status: "failed" }

      expect(response).to redirect_to(account_path)
      expect(flash[:alert]).to eq("Checkout didn't go through, so nothing was charged.")
    end
  end

  context "in live mode with Dodo" do
    let(:live_env) do
      { "BILLING_MODE" => "live", "DODO_API_KEY" => "live_key_not_real", "DODO_ENVIRONMENT" => "live_mode",
        "DODO_PRODUCT_CREATOR_MONTHLY" => "pdt_live_creator_monthly" }
    end

    around { |example| with_billing_env(live_env) { example.run } }

    it "redirects to Dodo's hosted checkout, returning to the thanks page" do
      stub = stub_request(:post, "https://live.dodopayments.com/checkouts")
        .with { |request| JSON.parse(request.body)["return_url"] == "http://www.example.com/billing/success" }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { session_id: "cks_1", checkout_url: "https://checkout.dodopayments.com/session/cks_1" }.to_json)
      sign_in user

      post "/checkouts", params: { price_key: "creator_monthly" }

      expect(response).to redirect_to("https://checkout.dodopayments.com/session/cks_1")
      expect(stub).to have_been_requested
    end

    it "sends the buyer back with an alert when Dodo fails or the product isn't configured" do
      allow(Rails.logger).to receive(:error)
      stub_request(:post, "https://live.dodopayments.com/checkouts").to_return(status: 401, body: "{}")
      sign_in user

      post "/checkouts", params: { price_key: "creator_monthly" }
      expect(response).to redirect_to(pricing_path)
      expect(flash[:alert]).to eq("We couldn't start checkout. Please try again.")

      post "/checkouts", params: { price_key: "pro_monthly" }
      expect(response).to redirect_to(pricing_path)
      expect(Rails.logger).to have_received(:error).with(/DODO_PRODUCT_PRO_MONTHLY/)
    end

    it "falls back to the waitlist (404) when the environment isn't live_mode" do
      allow(Rails.logger).to receive(:warn)
      with_billing_env(live_env.merge("DODO_ENVIRONMENT" => "test_mode")) do
        sign_in user
        post "/checkouts", params: { price_key: "creator_monthly" }
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
