require "rails_helper"

RSpec.describe "Waitlist entries" do
  let(:confirmation) { "You're on the founding-member list — we'll email you when paid plans open." }

  around { |example| with_billing_env { example.run } }

  it "adds a signed-in user by their account email, with no email to type" do
    user = create(:user, email: "Ada@Example.com")
    sign_in user

    post "/waitlist_entries", params: { price_key: "pro_monthly" }, headers: { "HTTP_REFERER" => "http://www.example.com/account" }

    expect(WaitlistEntry.sole).to have_attributes(email: "ada@example.com", price_key: "pro_monthly", user: user)
    expect(response).to redirect_to("/account")
    expect(flash[:notice]).to eq(confirmation)
  end

  it "adds a signed-out visitor by the email they give" do
    post "/waitlist_entries", params: { email: "  Grace@Example.com ", price_key: "sprint" }

    expect(WaitlistEntry.sole).to have_attributes(email: "grace@example.com", price_key: "sprint", user: nil)
    expect(response).to redirect_to(pricing_path)
    expect(flash[:notice]).to eq(confirmation)
  end

  it "refuses an email that isn't one" do
    post "/waitlist_entries", params: { email: "not-an-email", price_key: "sprint" }
    post "/waitlist_entries", params: { price_key: "sprint" }

    expect(WaitlistEntry.count).to eq(0)
    expect(flash[:alert]).to eq("Enter a valid email address.")
  end

  it "treats a repeat, in any case, as a friendly no-op with the same confirmation" do
    post "/waitlist_entries", params: { email: "grace@example.com", price_key: "sprint" }
    post "/waitlist_entries", params: { email: "GRACE@example.COM", price_key: "sprint" }

    expect(WaitlistEntry.count).to eq(1)
    expect(flash[:notice]).to eq(confirmation)

    post "/waitlist_entries", params: { email: "grace@example.com", price_key: "creator_monthly" }
    expect(WaitlistEntry.count).to eq(2)
  end

  it "takes the notify key (Task 18) but no key outside plans.yml" do
    sign_in create(:user, email: "grace@example.com")
    post "/waitlist_entries", params: { price_key: "notify" }
    expect(WaitlistEntry.sole.price_key).to eq("notify")

    post "/waitlist_entries", params: { email: "grace@example.com", price_key: "enterprise" }
    expect(WaitlistEntry.count).to eq(1)
    expect(flash[:alert]).to eq("Pick a plan to join the waitlist for.")
  end

  it "sends a signed-out visitor to sign in for the notify key, whatever email they give" do
    post "/waitlist_entries", params: { email: "someone-else@example.com", price_key: "notify" }

    expect(response).to redirect_to("/users/sign_in")
    expect(WaitlistEntry.count).to eq(0)
  end

  it "stays open whatever the billing mode" do
    with_billing_env("BILLING_MODE" => "test") do
      post "/waitlist_entries", params: { email: "grace@example.com", price_key: "pro_yearly" }
    end
    expect(WaitlistEntry.count).to eq(1)
  end

  it "is rate-limited per IP" do
    allow(WaitlistEntriesController.cache_store).to receive(:increment).and_return(11)

    post "/waitlist_entries", params: { email: "grace@example.com", price_key: "sprint" }

    expect(WaitlistEntry.count).to eq(0)
    expect(response).to redirect_to(pricing_path)
    expect(flash[:alert]).to eq("Too many tries. Please try again later.")
  end
end
