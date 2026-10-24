require "rails_helper"

RSpec.describe Research::Names do
  describe ".normalize" do
    it "downcases and strips whitespace, trailing punctuation, a leading 'the' and domain suffixes" do
      expect(described_class.normalize("  The Notion. ")).to eq("notion")
      expect(described_class.normalize("acme.com")).to eq("acme")
      expect(described_class.normalize("Booking.com")).to eq("booking")
      expect(described_class.normalize("The Founder's Ledger")).to eq("foundersledger")
      expect(described_class.normalize("Marlow & Finch")).to eq("marlowandfinch")
      expect(described_class.normalize("Theo Park")).to eq("theopark")
      expect(described_class.normalize(nil)).to eq("")
    end
  end

  describe ".same?" do
    it "matches names that normalize equally" do
      expect(described_class.same?("Rocket Money", "rocketmoney.com")).to be(true)
      expect(described_class.same?("HelloFresh", "hellofresh")).to be(true)
      expect(described_class.same?("Notion", "Notion Labs")).to be(false)
      expect(described_class.same?("", "")).to be(false)
    end
  end

  describe ".close?" do
    it "accepts equality or containment of at least 4 characters" do
      expect(described_class.close?("Founders Ledger", "The Founder's Ledger")).to be(true)
      expect(described_class.close?("Tim Ferriss", "The Tim Ferriss Show")).to be(true)
      expect(described_class.close?("art", "Smart Money")).to be(false)
      expect(described_class.close?("Nonexistent Pod Zzz", "Pickup Game Podcast")).to be(false)
      expect(described_class.close?(" ", "Anything")).to be(false)
    end
  end
end
