require "rails_helper"

# Brand.resolve as sponsor detection uses it (lane L2): the spec's basic cases are in brand_spec.rb.
RSpec.describe "Brand resolution" do
  it "names a brand after its domain when only the domain is known, and takes the first real name later" do
    brand = Brand.resolve(name: "", domain: "https://www.Manscaped.com/tim")
    expect(brand).to have_attributes(name: "manscaped.com", domain: "manscaped.com")

    expect(Brand.resolve(name: "manscaped.com", domain: "manscaped.com")).to eq(brand)
    expect(brand.reload.name).to eq("manscaped.com")
    expect(Brand.resolve(name: "Manscaped", domain: "manscaped.com")).to eq(brand)
    expect(brand.reload).to have_attributes(name: "Manscaped", name_key: "manscaped")
    expect(Brand.resolve(name: "Manscaped Inc", domain: "manscaped.com").reload.name).to eq("Manscaped")
  end

  it "finds a brand named after its domain by the name alone" do
    brand = Brand.resolve(name: "athleticgreens.com", domain: "athleticgreens.com")
    expect(Brand.find_existing(name: "Athletic Greens")).to eq(brand)
  end

  it "keeps a free mail domain off a brand found by name" do
    proton = Brand.resolve(name: "Proton", domain: "proton.me")
    expect(proton.domain).to be_nil
  end

  it "works inside a transaction that goes on afterwards, and looks again when a parallel resolve wins" do
    winner = create(:brand, name: "Ramp", domain: "ramp.com")
    calls = 0
    # The first look at the domain misses, as if the parallel resolve committed just after it.
    allow(Brand).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
      conditions = kwargs.presence || args.first
      next original.call(*args, **kwargs) unless conditions == { domain: "ramp.com" }

      calls += 1
      calls == 1 ? nil : original.call(*args, **kwargs)
    end

    Brand.transaction do
      expect(Brand.resolve(name: "Ramp", domain: "ramp.com")).to eq(winner)
      expect(Brand.for_onboarding(name: "Ramp", website: "ramp.com")).to eq(winner)
      expect(Brand.count).to eq(1)
    end
    expect(calls).to eq(3)
  end
end
