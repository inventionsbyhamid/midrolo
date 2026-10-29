require "rails_helper"

RSpec.describe Brand do
  describe ".normalize_domain" do
    it "keeps the registrable part of a host, lowercase, without www" do
      expect(described_class.normalize_domain("https://www.Notion.so/product?x=1")).to eq("notion.so")
      expect(described_class.normalize_domain("shop.example.co.uk")).to eq("example.co.uk")
      expect(described_class.normalize_domain("get.ag1.com:443")).to eq("ag1.com")
      expect(described_class.normalize_domain("sponsors@mercury.com")).to eq("mercury.com")
      expect(described_class.normalize_domain("not a domain")).to be_nil
      expect(described_class.normalize_domain(nil)).to be_nil
    end
  end

  describe ".resolve and .find_existing" do
    it "finds by domain, then by name, else creates" do
      notion = described_class.resolve(name: "Notion", domain: "notion.so")
      expect(notion).to have_attributes(name: "Notion", domain: "notion.so", name_key: "notion")
      expect(notion.slug).to start_with("notion-")

      expect(described_class.resolve(name: "Notion Labs", domain: "https://www.notion.so")).to eq(notion)
      expect(described_class.resolve(name: " notion ")).to eq(notion)
      expect { described_class.resolve(name: "Squarespace") }.to change(described_class, :count).by(1)
    end

    it "gives a brand found by name the domain it lacked, but keeps brands with other domains apart" do
      mercury = described_class.resolve(name: "Mercury")
      expect(described_class.resolve(name: "Mercury", domain: "mercury.com")).to eq(mercury)
      expect(mercury.reload.domain).to eq("mercury.com")

      other = described_class.resolve(name: "Mercury", domain: "mercuryinsurance.com")
      expect(other).not_to eq(mercury)
    end

    it "never takes free mail as a brand's domain" do
      brand = described_class.resolve(name: "Joe's Coffee", domain: "joe@gmail.com")
      expect(brand.domain).to be_nil
      expect(build(:brand, domain: "outlook.com")).not_to be_valid
    end

    it "only finds with find_existing" do
      expect { expect(described_class.find_existing(name: "Ramp")).to be_nil }.not_to change(described_class, :count)
      ramp = create(:brand, name: "Ramp", domain: "ramp.com")
      expect(described_class.find_existing(name: "RAMP")).to eq(ramp)
      expect(described_class.find_existing(name: "Anything", domain: "www.ramp.com")).to eq(ramp)
    end

    it "needs a name or a domain" do
      expect { described_class.resolve(name: " ") }.to raise_error(ArgumentError)
    end
  end

  it "counts its sponsor mentions" do
    brand = create(:brand)
    create_list(:sponsor_mention, 2, brand: brand)
    expect(brand.reload.sponsor_mentions_count).to eq(2)
  end

  describe SponsorMention do
    it "is one per episode and brand, with short offer and evidence" do
      mention = create(:sponsor_mention)
      expect(mention.published_at).to eq(mention.episode.published_at)
      expect(build(:sponsor_mention, episode: mention.episode, brand: mention.brand)).not_to be_valid
      expect(build(:sponsor_mention, offer: "o" * 161)).not_to be_valid
      expect(build(:sponsor_mention, evidence: "e" * 241)).not_to be_valid
      expect(build(:sponsor_mention, detected_by: "guess")).not_to be_valid
      expect(build(:sponsor_mention, confidence: 1.5)).not_to be_valid
    end
  end

  describe BrandMember do
    it "joins a user to a brand once, unverified until the code checks out" do
      member = create(:brand_member)
      expect(member).to have_attributes(role: "owner", attempts: 0)
      expect(member).not_to be_verified
      expect(build(:brand_member, brand: member.brand, user: member.user)).not_to be_valid
      expect(member.user.brands).to eq([ member.brand ])
    end
  end
end
