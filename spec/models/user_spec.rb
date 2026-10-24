require "rails_helper"

RSpec.describe User do
  describe ".from_omniauth" do
    it "creates a user from the Google payload" do
      user = described_class.from_omniauth(mock_google_auth)

      expect(user).to be_persisted
      expect(user).to have_attributes(
        email: "ada@example.com", name: "Ada Lovelace", avatar_url: "https://example.com/ada.png",
        provider: "google_oauth2", uid: "g-123", admin: false, judge: false, promo_reports_used: 0
      )
    end

    it "returns the same record for the same uid and refreshes the profile" do
      first = described_class.from_omniauth(mock_google_auth)
      second = described_class.from_omniauth(mock_google_auth(name: "Ada L.", image: "https://example.com/new.png"))

      expect(second).to eq(first)
      expect(described_class.count).to eq(1)
      expect(second).to have_attributes(name: "Ada L.", avatar_url: "https://example.com/new.png")
    end
  end

  describe "#initials" do
    it "uses the name, falling back to the email" do
      expect(build(:user, name: "Ada Lovelace").initials).to eq("AL")
      expect(build(:user, name: "Ada").initials).to eq("A")
      expect(build(:user, name: nil, email: "zed@example.com").initials).to eq("Z")
    end
  end

  describe "developer strategy" do
    it "is only offered in development without Google keys" do
      expect(AuthConfig.developer_strategy?(env: "development", client_id: "")).to be true
      expect(AuthConfig.developer_strategy?(env: "development", client_id: nil)).to be true
      expect(AuthConfig.developer_strategy?(env: "development", client_id: "abc")).to be false
      expect(AuthConfig.developer_strategy?(env: "production", client_id: "")).to be false
      expect(AuthConfig.developer_strategy?(env: "test", client_id: "")).to be false
    end

    it "is not configured outside development" do
      expect(Devise.omniauth_configs.keys).to eq([ :google_oauth2 ])
    end
  end
end
