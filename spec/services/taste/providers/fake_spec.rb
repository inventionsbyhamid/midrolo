require "rails_helper"

RSpec.describe Taste::Providers::Fake do
  let(:fake) { described_class.new }
  let(:brand_category) { /\Aurn:tag:genre:brand:\w+\z/ }

  it "contains every fake sponsor as a brand, with the exact match first" do
    Podcasts::Directories::Fake::FAKE_SPONSORS.each do |name|
      result = fake.search(query: name, types: [ :brand ])
      expect(result.first&.name).to eq(name)
      expect(result.first.type).to eq(:brand)
    end
  end

  it "has a broad brand catalog with varied popularity and fake: ids" do
    all = fake.recommend(type: :brand, entity_ids: [ "x" ], take: 500)
    expect(all.size).to be >= 140
    expect(all.map(&:id)).to all(start_with("fake:"))
    expect(all.count { |e| e.popularity > 0.9 }).to be >= 3
    expect(all.count { |e| e.popularity < 0.6 }).to be >= 20
    categories = all.flat_map { |e| e.tags.map(&:id) }.grep(brand_category).uniq
    expect(categories.size).to eq(12)
  end

  it "has artists, tv shows and podcasts" do
    %i[artist tv_show podcast].each do |type|
      expect(fake.recommend(type: type, entity_ids: [ "x" ], take: 5)).not_to be_empty
    end
  end

  it "names its brand categories as Qloo does, with the and kept: Food and Beverage, Health and Wellness" do
    names = fake.find_tags(query: "and", types: [ described_class::BRAND_TAG_TYPE ], take: 50).to_h { |tag| [ tag.id, tag.name ] }
    expect(names).to include("urn:tag:genre:brand:food_and_beverage" => "Food and Beverage",
                             "urn:tag:genre:brand:health_and_wellness" => "Health and Wellness")
    expect(fake.search(query: "HelloFresh", types: [ :brand ]).first.tags.map(&:name)).to eq([ "Food and Beverage" ])
    expect(fake.find_tags(query: "Food & Beverage", types: [ described_class::BRAND_TAG_TYPE ]).first.id)
      .to eq("urn:tag:genre:brand:food_and_beverage")
  end

  describe "#search" do
    it "finds podcasts by name case-insensitively and returns [] for gibberish" do
      pod = fake.recommend(type: :podcast, entity_ids: [ "x" ], take: 1).first
      expect(fake.search(query: pod.name.upcase, types: [ :podcast ]).first.id).to eq(pod.id)
      expect(fake.search(query: "zzzqqq", types: [ :brand ])).to eq([])
    end

    it "honours take" do
      expect(fake.search(query: "a", types: [ :brand ], take: 3).size).to be <= 3
    end
  end

  describe "#recommend" do
    it "is deterministic for the same seeds and differs for different seeds" do
      a1 = fake.recommend(type: :brand, entity_ids: [ "x" ])
      a2 = described_class.new.recommend(type: :brand, entity_ids: [ "x" ])
      b = fake.recommend(type: :brand, entity_ids: [ "y" ])
      expect(a1.map(&:name)).to eq(a2.map(&:name))
      expect(a1.map(&:name)).not_to eq(b.map(&:name))
    end

    it "sorts by affinity descending, honours take, and every id is fake:-prefixed" do
      r = fake.recommend(type: :brand, entity_ids: [ "x" ], take: 7)
      expect(r.size).to eq(7)
      expect(r.map(&:affinity)).to eq(r.map(&:affinity).sort.reverse)
      expect(r.map(&:id)).to all(start_with("fake:"))
      expect(r.map(&:affinity)).to all(be_between(0, 1))
    end

    it "pages with offset or page" do
      all = fake.recommend(type: :brand, entity_ids: [ "x" ], take: 6)
      expect(fake.recommend(type: :brand, entity_ids: [ "x" ], take: 3, offset: 3)).to eq(all.last(3))
      expect(fake.recommend(type: :brand, entity_ids: [ "x" ], take: 3, page: 2)).to eq(all.last(3))
    end

    it "honours filter_tags and popularity_max" do
      r = fake.recommend(type: :brand, entity_ids: [ "x" ], filter_tags: [ "urn:tag:genre:brand:finance" ], popularity_max: 0.8, take: 50)
      expect(r).not_to be_empty
      expect(r.map(&:popularity).max).to be <= 0.8
      expect(r).to all(satisfy { |e| e.tags.map(&:id).include?("urn:tag:genre:brand:finance") })
    end

    it "excludes the seed entities themselves" do
      notion = fake.search(query: "Notion", types: [ :brand ]).first
      expect(fake.recommend(type: :brand, entity_ids: [ notion.id ], take: 500).map(&:id)).not_to include(notion.id)
    end

    it "rejects unknown types" do
      expect { fake.recommend(type: :spaceship) }.to raise_error(ArgumentError)
    end
  end

  describe "#affinity_for" do
    it "returns a deterministic 0..1 value per candidate" do
      ids = %w[fake:brand:a fake:brand:b]
      r = fake.affinity_for(candidate_ids: ids, entity_ids: [ "x" ])
      expect(r.keys).to eq(ids)
      expect(r.values).to all(be_between(0, 1))
      expect(fake.affinity_for(candidate_ids: ids, entity_ids: [ "x" ])).to eq(r)
    end
  end

  describe "interface parity" do
    it "gives Qloo and Fake the same public method signatures" do
      qloo = Taste::Providers::Qloo.new(api_key: "k")
      %i[search find_tags recommend affinity_for taste_tags demographics heatmap compare].each do |m|
        expect(fake.method(m).parameters).to eq(qloo.method(m).parameters), "#{m} differs"
      end
    end

    it "scores only catalog entities of the requested type, and every candidate is a key" do
      brand = fake.search(query: "Notion", types: [ :brand ]).first
      r = fake.affinity_for(candidate_ids: [ brand.id, "fake:other" ], type: :podcast)
      expect(r.keys).to eq([ brand.id, "fake:other" ])
      expect(r[brand.id]).to be_nil
      expect(r["fake:other"]).to be_a(Float)
      expect(fake.affinity_for(candidate_ids: [ brand.id ])[brand.id]).to be_a(Float)
    end
  end

  describe "#demographics" do
    it "returns leans in -1..1 for the documented buckets" do
      d = fake.demographics(entity_ids: [ "x" ])
      expect(d.age.keys).to eq(%w[24_and_younger 25_to_29 30_to_34 35_to_44 45_to_54 55_and_older])
      expect(d.gender.keys).to eq(%w[male female])
      expect((d.age.values + d.gender.values)).to all(be_between(-1, 1))
      expect(fake.demographics(entity_ids: [ "x" ])).to eq(d)
    end
  end

  describe "#heatmap" do
    it "returns 20-50 geohash points near the location for a country code or name, unnamed like Qloo's (R106)" do
      %w[US us].push("United States").each do |loc|
        pts = fake.heatmap(location: loc)
        expect(pts.size).to be_between(20, 50)
        expect(pts).to all(be_a(Taste::HeatPoint))
        expect(pts.map(&:lat)).to all(be_between(24, 50))
        expect(pts.map(&:label)).to all(be_nil)
        expect(pts.map(&:geohash)).to all(match(/\A[0-9b-hjkmnp-z]{7}\z/))
        expect(pts.map(&:affinity)).to all(be_between(0, 1))
      end
    end

    it "handles metros, take, and unknown locations" do
      pts = fake.heatmap(location: "Austin", entity_ids: [ "x" ])
      expect(pts.map { |p| Research::Places.name_for(p.lat, p.lng) }.uniq).to eq([ "Austin" ])
      expect(pts.map(&:lat)).to all(be_within(1).of(30.27))
      expect(fake.heatmap(location: "US", take: 21).size).to be <= 21
      expect(fake.heatmap(location: "Atlantis")).to eq([])
    end

    it "has coordinates for every metro in config/geo.yml and the five countries" do
      geo = YAML.load_file(Rails.root.join("config/geo.yml")).fetch("shared")
      geo.each do |code, metros|
        expect(fake.heatmap(location: code)).not_to be_empty
        metros.each { |m| expect(fake.heatmap(location: m)).not_to be_empty, "missing #{m}" }
      end
      expect(geo.keys).to match_array(%w[US GB CA AU IN])
    end
  end

  describe "#compare" do
    it "returns 5-10 shared tags" do
      tags = fake.compare(a_entity_ids: [ "a" ], b_entity_ids: [ "b" ])
      expect(tags.size).to be_between(5, 10)
      expect(tags).to all(be_a(Taste::Tag))
      expect(fake.compare(a_entity_ids: [ "a" ], b_entity_ids: [ "b" ], take: 6).size).to be <= 6
    end
  end

  describe "tags" do
    it "keeps to the tag types asked for, by exact match (M4)" do
      expect(fake.find_tags(query: "finance").map(&:type).uniq).to include("urn:tag:genre:brand", "urn:tag:interest")
      expect(fake.find_tags(query: "finance", types: [ "urn:tag:genre:brand" ]).map(&:id)).to eq([ "urn:tag:genre:brand:finance" ])
      expect(fake.find_tags(query: "finance", types: [ "urn:tag:genre" ])).to eq([])
    end

    it "has the podcast genre tags the category mapping needs" do
      %w[business technology comedy health_fitness education true_crime sports society_culture].each do |g|
        expect(fake.find_tags(query: g.tr("_", " ")).map(&:id)).to include("urn:tag:genre:media:#{g}")
      end
    end

    it "returns deterministic taste tags capped by take" do
      t = fake.taste_tags(entity_ids: [ "x" ], take: 8)
      expect(t.size).to eq(8)
      expect(t.map(&:score)).to eq(t.map(&:score).sort.reverse)
      expect(fake.taste_tags(entity_ids: [ "x" ], take: 8)).to eq(t)
    end
  end

  it "emits request.taste notifications for every call" do
    events = []
    sub = ActiveSupport::Notifications.subscribe("request.taste") { |*, p| events << p }
    fake.search(query: "Notion", types: [ :brand ])
    fake.demographics(entity_ids: [ "x" ])
    expect(events.map { |e| e[:path] }).to eq(%w[fake:search fake:demographics])
    expect(events).to all(include(cached: false, status: 200))
    expect(events.first[:duration_ms]).to be_a(Numeric)
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end
end
