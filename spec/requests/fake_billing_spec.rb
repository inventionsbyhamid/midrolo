require "rails_helper"

# The Fake billing provider's development pages (R71): checkout completes a test payment through the real, signed
# /webhooks/fake path, and the portal is a stand-in.
RSpec.describe "Fake billing (development)" do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }

  around { |example| with_billing_env("BILLING_MODE" => "test") { example.run } }

  it "requires sign-in" do
    get "/fake_checkout", params: { price_key: "pro_monthly" }
    expect(response).to redirect_to("/users/sign_in")
  end

  it "shows the plan with a button to complete the test payment" do
    sign_in user
    get "/fake_checkout", params: { price_key: "pro_monthly", user_id: user.id }

    page = Nokogiri::HTML(response.body)
    expect(page.text.squish).to include("Test checkout (development)", "Pro", "$49/month", "Nothing is charged.")
    form = page.at_css("form[action='/fake_checkout']")
    expect(form.at_css("input[name=price_key]")["value"]).to eq("pro_monthly")
    expect(form.at_css("[type=submit]").text.squish).to eq("Complete test payment")
  end

  it "returns 404 for a price key that isn't in plans.yml" do
    sign_in user
    get "/fake_checkout", params: { price_key: "enterprise" }
    expect(response).to have_http_status(:not_found)
  end

  it "completes a subscription through the signed webhook path, then lands on the thanks page" do
    sign_in user

    perform_enqueued_jobs { post "/fake_checkout", params: { price_key: "pro_monthly" } }

    expect(response).to redirect_to("/billing/success?status=active")
    expect(BillingEvent.sole).to have_attributes(provider: "fake", event_type: "subscription_active",
                                                 event_id: start_with("msg_fake_"), processed_at: be_present)
    expect(user.subscriptions.sole).to have_attributes(provider: "fake", plan: "pro", status: "active",
                                                       provider_customer_id: "fake_cus_#{user.id}")
    follow_redirect!
    follow_redirect!
    expect(response.body).to include("Thanks — your plan updates in a few seconds.", "Manage billing")
  end

  it "completes a sprint as a one-time payment" do
    sign_in user

    perform_enqueued_jobs { post "/fake_checkout", params: { price_key: "sprint" } }

    expect(response).to redirect_to("/billing/success?status=succeeded")
    expect(user.subscriptions.sole).to have_attributes(plan: "sprint", payment_ids: [ start_with("fake_pay_") ])
  end

  it "goes through the real signature check: a bad signature is refused" do
    fake = Billing::Providers::Fake.new
    allow(fake).to receive(:signed_headers)
      .and_return("webhook-id" => "msg_forged", "webhook-timestamp" => Time.current.to_i.to_s, "webhook-signature" => "v1,Zm9yZ2Vk")
    allow(Billing::Providers::Fake).to receive(:new).and_return(fake)
    sign_in user

    post "/fake_checkout", params: { price_key: "pro_monthly" }

    expect(response).to redirect_to(account_path)
    expect(flash[:alert]).to eq("The test payment's webhook was refused (HTTP 400).")
    expect(BillingEvent.count).to eq(0)
  end

  it "shows a stand-in portal with a way back" do
    sign_in user
    get "/fake_portal", params: { customer_id: "fake_cus_1" }

    expect(response.body).to include("Fake billing portal (development)")
    back = Nokogiri::HTML(response.body).css("main a").find { |link| link.text.squish == "Back to your account" }
    expect(back["href"]).to eq("/account")
  end
end
