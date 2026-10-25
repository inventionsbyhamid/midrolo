require "rails_helper"

# The hackathon promo's banner shows only to signed-in users on the promo plan (R63).
RSpec.describe "Promo banner" do
  let(:copy) { "Free Pro access during the Qloo hackathon judging — through Nov 6." }

  def banner = Nokogiri::HTML(response.body).at_css(".promo-banner")

  around { |example| travel_to(Time.zone.local(2026, 10, 25, 12)) { example.run } }

  before { AppSettings.set(:promo_pro_until, "2026-11-06") }

  it "shows on app pages to a signed-in user on the promo" do
    sign_in create(:user)
    get "/account"
    expect(banner.text.squish).to eq(copy)
  end

  it "doesn't show to judges, subscribers, or anyone once the promo is over" do
    sign_in create(:user, judge: true)
    get "/account"
    expect(banner).to be_nil

    sign_in create(:user, :subscribed)
    get "/account"
    expect(banner).to be_nil

    sign_in create(:user)
    travel 13.days # Nov 7
    get "/account"
    expect(banner).to be_nil
  end

  it "doesn't show signed out" do
    get "/users/sign_in"
    expect(response.body).not_to include("Free Pro access")
  end
end
