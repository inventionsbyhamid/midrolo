require "rails_helper"

RSpec.describe Podcasts::Directories::Fake do
  subject(:fake) { described_class.new }

  it "has about a dozen shows with fake-N ids covering the categories" do
    expect(described_class::CATALOG.size).to be_between(11, 14)
    ids = described_class::CATALOG.map { |s| s[:directory_id] }
    expect(ids).to include("fake-1", "fake-2", "fake-3")
    cats = described_class::CATALOG.flat_map { |s| s[:categories] }.uniq
    expect(cats).to include("Business", "Technology", "Comedy", "Health", "True Crime", "Education", "Sports")
  end

  it "exposes the sponsor list" do
    expect(described_class::FAKE_SPONSORS).to eq([ "Notion", "Squarespace", "Shopify", "HelloFresh", "Calm", "Mercury", "Ramp", "Linear", "AG1", "Rocket Money" ])
  end

  describe "#search" do
    it "returns 5 deterministic shows for finance" do
      a = fake.search("finance")
      expect(a.size).to eq(5)
      expect(a).to all(be_a(Podcasts::ShowInfo))
      expect(fake.search("FINANCE")).to eq(a)
    end

    it "matches title, author and category words case-insensitively" do
      expect(fake.search("comedy")).not_to be_empty
      expect(fake.search("zzzznothing")).to eq([])
    end

    it "honors limit" do
      expect(fake.search("finance", limit: 2).size).to eq(2)
    end

    it "gives fake:// feed urls" do
      expect(fake.search("finance").map(&:feed_url)).to all(match(%r{\Afake://fake-\d+\z}))
    end
  end

  it "finds by id and feed url" do
    show = fake.find("fake-2")
    expect(show.directory_id).to eq("fake-2")
    expect(fake.find_by_feed_url("fake://fake-2")).to eq(show)
    expect(fake.find("fake-999")).to be_nil
    expect(fake.find_by_feed_url("https://nope.example.com")).to be_nil
  end

  describe ".feed_for" do
    let(:feed) { described_class.feed_for("fake-1") }

    it "is deterministic with 15-20 weekly episodes" do
      expect(feed).to eq(described_class.feed_for("fake-1"))
      expect(feed.episodes.size).to be_between(15, 20)
      expect(feed.cadence_days).to eq(7)
      expect(feed.owner_email).to match(/\Ahost@[a-z0-9-]+\.example\z/)
      gaps = feed.episodes.map(&:published_at).each_cons(2).map { |a, b| (a - b) / 86_400 }
      expect(gaps.uniq).to eq([ 7.0 ])
      expect(feed.warnings).to eq([])
    end

    it "mentions sponsors in about a third of episodes" do
      all = described_class::CATALOG.map { |s| described_class.feed_for(s[:directory_id]) }.flat_map(&:episodes)
      with = all.select { |e| described_class::FAKE_SPONSORS.any? { |n| e.description.include?(n) } }
      ratio = with.size.to_f / all.size
      expect(ratio).to be_between(0.25, 0.42)
    end

    it "returns nil for an unknown id" do
      expect(described_class.feed_for("fake-999")).to be_nil
    end
  end
end

RSpec.describe Podcasts::Directories::Fake, "#find_by_itunes_id" do
  subject(:fake) { described_class.new }

  it "gives every fake show a deterministic, unique itunes_id" do
    ids = described_class::CATALOG.map { |s| fake.find(s[:directory_id]).itunes_id }
    expect(ids).to all(match(/\A\d+\z/))
    expect(ids.uniq.size).to eq(ids.size)
    expect(fake.find("fake-1").itunes_id).to eq(described_class.new.find("fake-1").itunes_id)
  end

  it "finds a show by its itunes id, as a string or integer" do
    id = fake.find("fake-3").itunes_id
    expect(fake.find_by_itunes_id(id).directory_id).to eq("fake-3")
    expect(fake.find_by_itunes_id(id.to_i).directory_id).to eq("fake-3")
  end

  it "returns nil for an unknown id" do
    expect(fake.find_by_itunes_id("42")).to be_nil
    expect(fake.find_by_itunes_id(nil)).to be_nil
  end
end
