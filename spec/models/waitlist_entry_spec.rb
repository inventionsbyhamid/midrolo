require "rails_helper"

RSpec.describe WaitlistEntry do
  it "downcases and strips the email" do
    expect(described_class.create!(email: "  Ada@Example.COM ", price_key: "sprint").email).to eq("ada@example.com")
  end

  it "validates the email's format and the price key" do
    expect(described_class.new(email: "ada", price_key: "sprint")).not_to be_valid
    expect(described_class.new(email: "ada@example.com", price_key: "enterprise")).not_to be_valid
    expect(described_class.new(email: "ada@example.com", price_key: "notify")).to be_valid
  end

  describe ".join" do
    it "finds the entry already there, in any case, rather than adding another" do
      first = described_class.join(email: "ada@example.com", price_key: "sprint")
      again = described_class.join(email: "ADA@example.com", price_key: "sprint")

      expect(again).to eq(first)
      expect(described_class.count).to eq(1)
    end

    it "links a signed-in user to an entry they made signed out" do
      described_class.join(email: "ada@example.com", price_key: "sprint")
      user = create(:user, email: "ada@example.com")

      expect(described_class.join(email: user.email, price_key: "sprint", user: user).user).to eq(user)
    end

    it "returns an unsaved entry with errors when invalid" do
      entry = described_class.join(email: "nope", price_key: "sprint")
      expect(entry).not_to be_persisted
      expect(entry.errors[:email]).to be_present
    end
  end
end
