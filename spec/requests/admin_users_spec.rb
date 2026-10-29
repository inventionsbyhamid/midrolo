require "rails_helper"

# R150: the admin's list of sign-ups, newest first, searchable by name or email.
RSpec.describe "Admin sign-ups" do
  let(:admin) { create(:user, admin: true, name: "Ops", email: "ops@example.com") }

  it "is not found for anyone but an admin" do
    get admin_users_path
    expect(response).to have_http_status(:not_found)

    sign_in create(:user)
    get admin_users_path
    expect(response).to have_http_status(:not_found)
  end

  context "as an admin" do
    before { sign_in admin }

    it "lists each sign-up's name and email, newest first, with counts and no samples owner" do
      old = create(:user, name: "Ada Lovelace", email: "ada@example.com", created_at: 3.days.ago)
      new = create(:user, name: "Grace Hopper", email: "grace@example.com")
      create(:show, user: new)
      User.create!(email: User::SAMPLES_EMAIL, name: "Samples")

      get admin_users_path

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
      rows = Nokogiri::HTML(response.body).css("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }
      expect(rows.map { |row| row[1] }).to eq([ "grace@example.com", "ops@example.com", "ada@example.com" ])
      expect(rows.first[0]).to eq("Grace Hopper")
      expect(rows.first[4]).to eq("1")
      expect(response.body).not_to include(User::SAMPLES_EMAIL)
      expect(old).to be_persisted
    end

    it "finds people by name or email, whatever the case" do
      create(:user, name: "Ada Lovelace", email: "ada@example.com")
      create(:user, name: "Grace Hopper", email: "grace@example.com")

      get admin_users_path(q: "LOVE")
      expect(response.body).to include("ada@example.com")
      expect(response.body).not_to include("grace@example.com")

      get admin_users_path(q: "grace@")
      expect(response.body).to include("Grace Hopper")
      expect(response.body).not_to include("Ada Lovelace")
    end

    it "offers View as for other users, never for an admin or yourself" do
      create(:user, name: "Ada Lovelace", email: "ada@example.com")
      create(:user, admin: true, email: "boss@example.com")

      get admin_users_path

      forms = Nokogiri::HTML(response.body).css("form[action='/admin/masquerade']")
      expect(forms.map { |form| form.at_css("input[name=email]")["value"] }).to eq([ "ada@example.com" ])
    end
  end
end
