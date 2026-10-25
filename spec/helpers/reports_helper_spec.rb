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
    it "uses plain words, never numbers or jargon, and lights at least one segment for any real lean" do
      expect([ 0.4, 0.1, 0.02, -0.1, -0.4 ].map { |v| helper.lean_word(v) })
        .to eq([ "Well above average", "A bit above average", "About average", "A bit below average", "Well below average" ])
      expect(helper.lean_segments(0.06, 0.6)).to eq(1)
      expect(helper.lean_segments(-0.6, 0.6)).to eq(10)
      expect(helper.lean_segments(0.01, 0.6)).to eq(0)
    end
  end

  describe "#gender_line" do
    it "says which way the audience leans in one plain line" do
      expect(helper.gender_line("male" => 0.3, "female" => -0.3)).to eq("Leans strongly toward men")
      expect(helper.gender_line("male" => -0.1, "female" => 0.12)).to eq("Leans a little toward women")
      expect(helper.gender_line("male" => 0.02, "female" => -0.01)).to eq("About even between men and women")
      expect(helper.gender_line({})).to be_nil
    end
  end

  describe "#taste_band" do
    it "puts a Qloo score in plain words, with no number, and shows no band below the floor (R102)" do
      expect([ 0.97, 0.8, 0.6, 0.5, 0.49, 0.2, nil ].map { |score| helper.taste_band(score) })
        .to eq([ "Far more than most", "Much more than most", "More than most", "More than most", nil, nil, nil ])
    end
  end

  describe "#category_label" do
    it "spells & and _and_ as and, never dropping it" do
      expect(helper.category_label("Food & Beverage")).to eq("Food and Beverage")
      expect(helper.category_label("Health&Wellness")).to eq("Health and Wellness")
      expect(helper.category_label("food_and_beverage")).to eq("Food and Beverage")
      expect(helper.category_label("Food and Beverage")).to eq("Food and Beverage")
      expect(helper.category_label("Technology")).to eq("Technology")
      expect(helper.category_label(nil)).to be_nil
    end
  end

  describe "#best_fits" do
    it "takes the top 3 by fit score" do
      matches = [ build(:sponsor_match, name: "A", fit_score: 60, position: 1), build(:sponsor_match, name: "B", fit_score: 95, position: 2),
                  build(:sponsor_match, name: "C", fit_score: 80, position: 3), build(:sponsor_match, name: "D", fit_score: 50, position: 4) ]
      expect(helper.best_fits(matches).map(&:name)).to eq(%w[B C A])
    end
  end

  describe "#top_tastes" do
    it "takes up to 8 names across the groups in turn and keeps them grouped, in group order" do
      groups = [ [ "Interests", %w[i1 i2 i3 i4] ], [ "Brands", %w[b1 b2 b3] ], [ "Podcasts", %w[p1] ], [ "TV", [] ],
                 [ "Music", %w[m1 m2 m3] ] ]
      expect(helper.top_tastes(groups)).to eq([ [ "Interests", %w[i1 i2 i3] ], [ "Brands", %w[b1 b2] ], [ "Podcasts", %w[p1] ],
                                                [ "Music", %w[m1 m2] ] ])
      expect(helper.top_tastes([ [ "Interests", %w[a b] ] ], limit: 8)).to eq([ [ "Interests", %w[a b] ] ])
    end
  end

  describe "#top_places" do
    it "names the 3 strongest places in words, grouped by label and ranked by summed affinity" do
      points = [ { "label" => "Austin", "affinity" => 0.5 }, { "label" => "Austin", "affinity" => 0.5 },
                 { "label" => "Denver", "affinity" => 0.9 }, { "label" => "Boise", "affinity" => 0.4 },
                 { "label" => "Reno", "affinity" => 0.1 }, { "label" => nil, "affinity" => 1 } ]
      expect(helper.top_places(points)).to eq("Austin, Denver and Boise")
      expect(helper.top_places([ { "label" => "Austin", "affinity" => 0 } ])).to eq("Austin")
      expect(helper.top_places([])).to be_nil
    end
  end

  describe "#evidence_chips" do
    it "reads symbol-keyed evidence: shared tastes, the newest proven show and how many other shows, at most 3" do
      match = build(:sponsor_match, affinity: 0.82, evidence: {
        shared_tags: [ "Investing" ],
        proven: { items: [ { show: "Harbor Lights", published_at: Time.utc(2025, 3, 2) }, { show: "Tide Tables" },
                           { show: "Harbor Lights" } ], count: 7 }
      })
      expect(helper.evidence_chips(match).map { |chip| Nokogiri::HTML5.fragment(chip).text })
        .to eq([ "Shares 1 taste", "Sponsors Harbor Lights", "+1 more show" ]) # shows, not the 7 episodes
    end

    it "leaves out the count when every sponsorship is on the same show" do
      match = build(:sponsor_match, evidence: { "shared_tags" => [], "proven" => { "items" => [ { "show" => "Harbor Lights" }, { "show" => "Harbor Lights" } ], "count" => 5 } })
      expect(helper.evidence_chips(match).map { |chip| Nokogiri::HTML5.fragment(chip).text }).to eq([ "Sponsors Harbor Lights" ])
    end

    it "never shows a score, and says a similar show when the proven one has no name" do
      match = build(:sponsor_match, affinity: 0.82, evidence: { "shared_tags" => [], "proven" => { "items" => [ { "show" => nil } ], "count" => 1 } })
      expect(helper.evidence_chips(match).map { |chip| Nokogiri::HTML5.fragment(chip).text }).to eq([ "Sponsors a similar show" ])
    end
  end

  describe "#match_reason_line" do
    it "keeps a reason within 25 words as it is and cuts an older, longer one to its first sentence" do
      expect(helper.match_reason_line(build(:sponsor_match, reason: "Fits well."))).to eq("Fits well.")
      long = "Fits this audience very well. #{'More words here. ' * 10}"
      expect(helper.match_reason_line(build(:sponsor_match, reason: long))).to eq("Fits this audience very well.")
      expect(helper.match_reason_line(build(:sponsor_match, reason: nil))).to be_nil
    end
  end

  it "takes the stylesheet from the pinned MapLibre build" do
    expect(helper.maplibre_stylesheet_url).to match(%r{\Ahttps://cdn\.jsdelivr\.net/npm/maplibre-gl@\d+\.\d+\.\d+/dist/maplibre-gl\.css\z})
  end
end
