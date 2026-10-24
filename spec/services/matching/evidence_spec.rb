require "rails_helper"

RSpec.describe Matching::Evidence do
  let(:time) { Time.zone.local(2026, 10, 12, 9) }
  let(:in_memory) { { items: [ { show: "S", episode_title: "E", published_at: time } ], count: 4 } }
  let(:from_json) { JSON.parse(in_memory.to_json) }

  it "reads items, count and published_at with symbol or string keys" do
    [ in_memory, from_json, from_json.with_indifferent_access ].each do |evidence|
      expect(described_class.count(evidence)).to eq(4)
      expect(described_class.items(evidence).size).to eq(1)
      expect(described_class.published_at(described_class.items(evidence).first)).to eq(time)
    end
  end

  it "treats missing or malformed evidence as none" do
    [ nil, {}, Matching::Candidate::NO_EVIDENCE, { "items" => nil, "count" => nil } ].each do |evidence|
      expect(described_class.items(evidence)).to eq([])
      expect(described_class.count(evidence)).to eq(0)
    end
    expect(described_class.published_at({ "published_at" => "not a date" })).to be_nil
    expect(described_class.published_at({ published_at: nil })).to be_nil
  end
end
