require "rails_helper"

# bin/setup's demo data (bin/rails demo:seed): only in development, only with the Fake taste provider and directory.
RSpec.describe DemoSeed do
  describe ".skip_reason" do
    it "seeds in development with the Fake taste provider and directory" do
      expect(described_class.skip_reason(env: "development")).to be_nil
    end

    it "stays out of every other environment" do
      expect(described_class.skip_reason(env: "production")).to eq("development only (this is production)")
      expect(described_class.skip_reason(env: "test")).to eq("development only (this is test)")
    end

    it "stays out when a live taste provider or directory is configured" do
      allow(Taste::Provider).to receive(:fake?).and_return(false)
      expect(described_class.skip_reason(env: "development")).to include("QLOO_API_KEY")

      allow(Taste::Provider).to receive(:fake?).and_return(true)
      allow(Podcasts::Directory).to receive(:fake?).and_return(false)
      expect(described_class.skip_reason(env: "development")).to include("Podcast Index")
    end
  end

  describe ".admin!" do
    it "makes the Dev sign in account for demo-admin@midrolo.test an admin, once" do
      expect(described_class.admin_ready?).to be(false)

      user = described_class.admin!
      expect(user).to have_attributes(provider: "developer", uid: "demo-admin@midrolo.test",
                                      email: "demo-admin@midrolo.test", name: "Demo Admin", admin: true)
      expect { described_class.admin! }.not_to change(User, :count)
      expect(described_class.admin_ready?).to be(true)
    end

    it "is the account the Dev sign in card signs in to with that email, and keeps the name it was given" do
      auth = OmniAuth::AuthHash.new(provider: "developer", uid: "demo-admin@midrolo.test",
                                    info: { name: "Judge", email: "demo-admin@midrolo.test" })
      signed_in = User.from_omniauth(auth)

      expect(described_class.admin!).to eq(signed_in)
      expect(signed_in.reload).to have_attributes(admin: true, name: "Judge")
    end
  end
end
