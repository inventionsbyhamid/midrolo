require "rails_helper"

RSpec.describe ReportsHelper do
  describe "#safe_external_url" do
    it "passes http(s) URLs and drops everything else" do
      expect(helper.safe_external_url("https://fieldnote.example.com/shop")).to eq("https://fieldnote.example.com/shop")
      expect(helper.safe_external_url("http://a.example.com")).to eq("http://a.example.com")
      [ "javascript:alert(1)", "data:text/html,hi", "//evil.example.com", "not a url", "", nil ].each do |url|
        expect(helper.safe_external_url(url)).to be_nil
      end
    end
  end

  describe "#age_bucket_label" do
    it "turns Qloo bucket keys into ranges" do
      expect(%w[24_and_younger 25_to_29 35_to_44 55_and_older].map { |b| helper.age_bucket_label(b) })
        .to eq([ "24 and under", "25 to 29", "35 to 44", "55+" ])
    end
  end

  describe "#lean_word and #lean_segments" do
    it "uses words, never numbers, and lights at least one segment for any real lean" do
      expect([ 0.4, 0.1, 0.02, -0.1, -0.4 ].map { |v| helper.lean_word(v) })
        .to eq([ "Over-indexes", "Slightly over", "About even", "Slightly under", "Under-indexes" ])
      expect(helper.lean_segments(0.06, 0.6)).to eq(1)
      expect(helper.lean_segments(-0.6, 0.6)).to eq(10)
      expect(helper.lean_segments(0.01, 0.6)).to eq(0)
    end
  end

  describe "#top_metros" do
    it "groups by label, ranks by summed affinity and scales to the top metro" do
      points = [ { "label" => "Austin", "affinity" => 0.5 }, { "label" => "Austin", "affinity" => 0.5 },
                 { "label" => "Denver", "affinity" => 0.5 }, { "label" => nil, "affinity" => 0.9 } ]
      expect(helper.top_metros(points)).to eq([ [ "Austin", 1.0 ], [ "Denver", 0.5 ] ])
    end

    it "copes with zero affinity" do
      expect(helper.top_metros([ { "label" => "Austin", "affinity" => 0 } ])).to eq([ [ "Austin", 0.0 ] ])
    end
  end

  describe "#evidence_chips" do
    it "reads symbol-keyed evidence and adds the year to an older sponsorship" do
      match = build(:sponsor_match, affinity: nil, evidence: {
        shared_tags: [ "Investing" ],
        proven: { items: [ { show: "Harbor Lights", published_at: Time.utc(2025, 3, 2) }, { show: nil } ], count: 2 }
      })
      expect(helper.evidence_chips(match).map { |chip| Nokogiri::HTML5.fragment(chip).text })
        .to eq([ "Shares 1 taste tag", "Sponsored Harbor Lights · Mar 2, 2025", "Sponsored a similar show" ])
    end
  end

  it "takes the stylesheet from the pinned MapLibre build" do
    expect(helper.maplibre_stylesheet_url).to match(%r{\Ahttps://cdn\.jsdelivr\.net/npm/maplibre-gl@\d+\.\d+\.\d+/dist/maplibre-gl\.css\z})
  end
end
