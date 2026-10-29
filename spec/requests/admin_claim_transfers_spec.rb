require "rails_helper"

RSpec.describe "Admin: moving a show to another owner" do
  let(:admin) { create(:user, admin: true) }
  let(:podcast) { create(:podcast, :active, title: "The Founder's Ledger") }
  let!(:new_owner) { create(:user, email: "real.host@example.com") }

  it "is a 404 for anyone but an admin" do
    sign_in create(:user)
    get new_admin_claim_transfer_path
    expect(response).to have_http_status(:not_found)
    post admin_claim_transfers_path, params: { podcast: podcast.slug, email: new_owner.email }
    expect(response).to have_http_status(:not_found)
    expect(podcast.reload).not_to be_claimed
  end

  context "as an admin" do
    before { sign_in admin }

    it "moves the show to the account, from its page URL" do
      old = create(:show, podcast: podcast)
      old.verify!(via: "email")
      get new_admin_claim_transfer_path
      expect(response.body).to include("Move a show to another owner")

      post admin_claim_transfers_path, params: { podcast: "https://midrolo.com/podcasts/#{podcast.slug}#rates", email: "Real.Host@example.com" }

      expect(response).to redirect_to(new_admin_claim_transfer_path)
      expect(flash[:notice]).to eq("The Founder's Ledger now belongs to real.host@example.com.")
      expect(podcast.reload.owner_show.user).to eq(new_owner)
      expect(old.reload).not_to be_verified
    end

    it "says what it couldn't find" do
      post admin_claim_transfers_path, params: { podcast: "no-such-show", email: new_owner.email }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("No podcast has that page or slug.")

      post admin_claim_transfers_path, params: { podcast: podcast.slug, email: "nobody@example.com" }
      expect(response.body).to include("No account has that email.")
    end
  end
end
