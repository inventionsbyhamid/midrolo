require "rails_helper"

RSpec.describe Pricing::RateCard do
  def call(downloads, *cats)
    described_class.call(downloads: downloads, categories: cats)
  end

  it "uses the floor in flat mode" do
    r = call(800, "Comedy")
    expect(r).to be_a(Pricing::RateCard::Result)
    expect([ r.mode, r.midroll, r.preroll, r.postroll, r.bundle4 ]).to eq([ :flat, 25, 20, 15, 90 ])
    expect(r.basis).to include("5,000")
  end

  it "applies the niche multiplier in flat mode, rounded to $5" do
    r = call(3000, "Business")
    expect(r.mode).to eq(:flat)
    expect(r.midroll).to eq(115)
    expect(r.preroll).to eq(90)
    expect(r.postroll).to eq(60)
  end

  it "uses CPM mode at 5,000 and above" do
    r = call(20_000, "Technology")
    expect([ r.mode, r.midroll, r.preroll, r.postroll, r.bundle4 ]).to eq([ :cpm, 750, 600, 375, 2700 ])
    expect(r.basis).to include("CPM")
  end

  it "treats nil downloads as 0 (flat at the floor)" do
    r = call(nil, "Business")
    expect([ r.mode, r.midroll ]).to eq([ :flat, 25 ])
  end

  it "takes the max niche multiplier, case-insensitive substring, with investing and money as finance" do
    expect(call(20_000, "Comedy", "Health & Fitness").midroll).to eq(600)
    expect(call(20_000, "Health & Fitness", "INVESTING").midroll).to eq(750)
    expect(call(20_000, "Personal Money").midroll).to eq(750)
    expect(call(20_000, "Comedy").midroll).to eq(500)
    expect(call(20_000).midroll).to eq(500)
  end
end
