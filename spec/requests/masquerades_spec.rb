require "rails_helper"

# R150: an admin signs in as a user to see what they see, with a banner the whole time and a button back.
RSpec.describe "Masquerade" do
  let(:admin) { create(:user, admin: true, email: "ops@example.com") }
  let(:user) { create(:user, name: "Ada Lovelace", email: "ada@example.com") }

  def banner = Nokogiri::HTML(response.body).at_css(".masquerade-banner")

  it "shows an admin the app as the user, leaves the user's sign-in stats alone, and comes back" do
    create(:show, user: user, title: "Ada's Show")
    user.update!(sign_in_count: 4, last_sign_in_at: 2.days.ago.round)
    sign_in admin

    post admin_masquerade_path, params: { email: " ADA@example.com " }
    expect(response).to redirect_to(shows_path)
    follow_redirect!

    expect(response.body).to include("Ada&#39;s Show")
    expect(banner.text.squish).to include("Viewing as Ada Lovelace (ada@example.com)")
    expect(user.reload.sign_in_count).to eq(4)

    get admin_root_path
    expect(response).to have_http_status(:not_found)

    delete admin_masquerade_path
    expect(response).to redirect_to(admin_users_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(banner).to be_nil
  end

  it "keeps the owner-only actions from the admin while it lasts" do
    sign_in admin
    post admin_masquerade_path, params: { email: user.email }

    delete account_path
    expect(flash[:alert]).to eq(ApplicationController::MASQUERADE_REFUSED)
    expect(User.exists?(user.id)).to be(true)

    post billing_portal_path
    expect(flash[:alert]).to eq(ApplicationController::MASQUERADE_REFUSED)
  end

  it "refuses an unknown email, yourself and other admins" do
    sign_in admin
    create(:user, admin: true, email: "boss@example.com")

    [ [ "nobody@example.com", "No user has that email." ], [ "ops@example.com", "That's you." ],
      [ "boss@example.com", "Admins can't view the app as another admin." ] ].each do |email, alert|
      post admin_masquerade_path, params: { email: email }
      expect(response).to redirect_to(admin_users_path)
      expect(flash[:alert]).to eq(alert)
    end

    get shows_path
    expect(banner).to be_nil
  end

  it "is not found for anyone but an admin, and stopping is not found when nothing is masqueraded" do
    sign_in user
    post admin_masquerade_path, params: { email: admin.email }
    expect(response).to have_http_status(:not_found)

    delete admin_masquerade_path
    expect(response).to have_http_status(:not_found)

    sign_in admin
    delete admin_masquerade_path
    expect(response).to have_http_status(:not_found)
  end
end
