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

    # Final review N3: the Public Suffix List, private suffixes included, so different companies never share a domain.
    it "keeps companies apart on every public suffix, hosted platforms included, and has no domain for a bare suffix" do
      expect(described_class.normalize_domain("https://shop.alpha.com.pl")).to eq("alpha.com.pl")
      expect(described_class.normalize_domain("beta.com.pl")).to eq("beta.com.pl")
      expect(described_class.normalize_domain("www.gamma.co.th/about")).to eq("gamma.co.th")
      expect(described_class.normalize_domain("alpha.myshopify.com")).to eq("alpha.myshopify.com")
      expect(described_class.normalize_domain("beta.myshopify.com")).to eq("beta.myshopify.com")
      expect(described_class.normalize_domain("someone.github.io")).to eq("someone.github.io")
      expect(described_class.normalize_domain("contoso.onmicrosoft.com")).to eq("contoso.onmicrosoft.com")
      %w[com.pl co.uk myshopify.com github.io onmicrosoft.com com].each do |suffix|
        expect(described_class.normalize_domain(suffix)).to be_nil
      end
    end

    it "still treats a site on a platform that is itself a public suffix as that platform for sponsor detection" do
      expect(Sponsors::Rules.platform_domain?(described_class.normalize_domain("https://myshow.blogspot.com/p/1"))).to be(true)
      expect(Sponsors::Rules.platform_domain?(described_class.normalize_domain("myshow.carrd.co"))).to be(true)
      expect(Sponsors::Rules.platform_domain?("acme.com")).to be(false)
    end
  end

  describe ".resolve and .find_existing" do
    it "finds by domain, then by name, else creates" do
      notion = described_class.resolve(name: "Notion", domain: "notion.so")
      expect(notion).to have_attributes(name: "Notion", domain: "notion.so", name_key: "notion")
      expect(notion.slug).to eq("notion")

      expect(described_class.resolve(name: "Notion Labs", domain: "https://www.notion.so")).to eq(notion)
      expect(described_class.resolve(name: " notion ")).to eq(notion)
      expect { described_class.resolve(name: "Squarespace") }.to change(described_class, :count).by(1)
    end

    # C1: a domain set on a brand found by name let anyone with a website of that name verify into it.
    it "never gives a brand found by name a domain: a known domain makes its own brand" do
      mercury = described_class.resolve(name: "Mercury")
      at_domain = described_class.resolve(name: "Mercury", domain: "mercury.com")

      expect(at_domain).not_to eq(mercury)
      expect(at_domain).to have_attributes(name: "Mercury", domain: "mercury.com")
      expect(at_domain.slug).not_to eq(mercury.slug)
      expect(mercury.reload.domain).to be_nil
      expect(described_class.resolve(name: "Mercury", domain: "mercury.com")).to eq(at_domain)

      other = described_class.resolve(name: "Mercury", domain: "mercuryinsurance.com")
      expect([ mercury, at_domain ]).not_to include(other)
    end

    it "never renames a brand it finds, except to write a domain's name properly" do
      acme = create(:brand, name: "Acme", domain: "acme.com")
      expect(described_class.resolve(name: "Evil Corp", domain: "acme.com")).to eq(acme)
      expect(acme.reload.name).to eq("Acme")

      named_after_domain = described_class.resolve(name: "", domain: "manscaped.com")
      expect(described_class.resolve(name: "Scam Shop", domain: "manscaped.com")).to eq(named_after_domain)
      expect(named_after_domain.reload.name).to eq("manscaped.com")
      described_class.resolve(name: "Manscaped", domain: "manscaped.com")
      expect(named_after_domain.reload.name).to eq("Manscaped")
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

  # "I'm a brand" (C1): the website decides. The brand already at it is joined as it is; otherwise a new brand is made,
  # even when brands of that name exist, and none of them changes.
  describe ".for_onboarding" do
    it "puts two companies under one two-label suffix in two brands, and refuses a bare suffix (N3)" do
      alpha = described_class.for_onboarding(name: "Alpha", website: "alpha.com.pl")
      beta = described_class.for_onboarding(name: "Beta", website: "https://beta.com.pl")
      expect([ alpha.domain, beta.domain ]).to eq(%w[alpha.com.pl beta.com.pl])
      expect(described_class.for_onboarding(name: "Shop", website: "alpha.myshopify.com"))
        .not_to eq(described_class.for_onboarding(name: "Other shop", website: "beta.myshopify.com"))
      expect { described_class.for_onboarding(name: "Poland", website: "com.pl") }.to raise_error(ArgumentError)
    end

    it "joins the brand at the website's domain without changing its name or domain" do
      acme = create(:brand, name: "Acme", domain: "acme.com")

      expect(described_class.for_onboarding(name: "Not Acme", website: "https://www.acme.com/about")).to eq(acme)
      expect(acme.reload).to have_attributes(name: "Acme", domain: "acme.com")
    end

    it "makes a new brand rather than giving a same-named brand the website" do
      detected = create(:brand, name: "Acme", domain: nil)
      create(:brand_member, brand: detected)

      brand = described_class.for_onboarding(name: "Acme", website: "evil.example")

      expect(brand).not_to eq(detected)
      expect(brand).to have_attributes(name: "Acme", domain: "evil.example")
      expect(brand.slug).not_to eq(detected.slug)
      expect(detected.reload.domain).to be_nil
      expect(described_class.where(name_key: "acme").count).to eq(2)
    end

    it "needs a website that isn't free mail" do
      expect { described_class.for_onboarding(name: "Acme", website: "") }.to raise_error(ArgumentError)
      expect { described_class.for_onboarding(name: "Acme", website: "gmail.com") }.to raise_error(ArgumentError)
      expect(described_class.count).to eq(0)
    end
  end

  # C1: a domain set after the fact is what let a stranger verify into a brand.
  it "keeps a brand's domain as it was made" do
    domainless = create(:brand, domain: nil)
    acme = create(:brand, domain: "acme.com")

    expect { domainless.update!(domain: "evil.example") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect { acme.update!(domain: "evil.example") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect([ domainless.reload.domain, acme.reload.domain ]).to eq([ nil, "acme.com" ])
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
