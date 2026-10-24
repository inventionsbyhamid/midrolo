require "rails_helper"

RSpec.describe Research::NumericClaims do
  let(:show) { create(:show, title: "The Founder's Ledger", feed_url: "fake://fake-1", downloads_per_episode: 1500) }
  let(:report) { create(:report, show: show, kind: "agent", status: "running") }
  let(:feed) do
    episodes = [ Podcasts::EpisodeInfo.new(title: "Ep. 112: Pricing your first product", description: "", published_at: Time.utc(2026, 10, 1), guid: "g1") ]
    Podcasts::Feed.new(title: "The Founder's Ledger", description: nil, owner_email: nil, owner_name: nil, episodes: episodes, cadence_days: 7, warnings: [])
  end
  let(:feed_reader) { instance_double(Podcasts::FeedReader, read: feed) }
  let(:toolkit) { Research::Toolkit.new(report, taste: Taste::Providers::Fake.new, feed_reader: feed_reader) }
  let(:shared_tags) { Array.new(6) { |i| Taste::Tag.new(id: "urn:tag:t#{i}", name: "Tag #{%w[A B C D E F][i]}", type: "urn:tag:interest", score: 0.5) } }
  let(:evidence) do
    { items: [ { show: "Index Fund Mornings", episode_title: "14. Cash flow surprises", published_at: Time.utc(2026, 9, 14) } ], count: 3 }
  end

  def scored(name: "Ramp", fit: 79, affinity: 0.823)
    brand = Taste::Entity.new(id: "fake:brand:#{name.parameterize}", name: name, type: :brand, popularity: 0.5, affinity: affinity,
                              image_url: nil, description: nil, website: nil, tags: [], properties: {})
    candidate = Matching::Candidate.new(entity: brand, affinity: affinity, proven_evidence: evidence, shared_tag_count: 0, category_match: false)
    Matching::Scored.new(candidate: candidate, fit_score: fit, tier: :easy_yes)
  end

  def unsupported_in(text, match = scored)
    toolkit.add_explanations(match.candidate.entity.id => shared_tags)
    claims = described_class.new(toolkit)
    claims.unsupported(text, claims.for_match(match))
  end

  it "extracts integers, decimals, percentages, multipliers and both ends of a range" do
    expect(described_class.tokens("40% of fans, 0.82 affinity, 2x more, 25–34, 1,500 downloads, 3rd pick")).to eq(
      [ "40%", "0.82", "2x", "25", "34", "1,500", "3rd" ]
    )
  end

  it "ignores digits glued to letters (AG1, 1Password, Web3)" do
    expect(described_class.tokens("AG1 and 1Password and Web3")).to eq([])
  end

  {
    "Reach 10k listeners." => [ "10k" ], "Reach 3.5k listeners." => [ "3.5k" ], "Reach 50K fans." => [ "50K" ],
    "Shows with 2M downloads trust it." => [ "2M" ], "Spends $5M on podcasts." => [ "$5M" ],
    "Fans in their 40s." => [ "40s" ], "Reaches 2 million fans." => [ "2 million" ],
    "25 percent of your listeners buy Ramp." => [ "25 percent" ], "40 % of fans buy Ramp." => [ "40 %" ],
    "Fans are 3x more likely to buy." => [ "3x" ], "Fans are x3 more likely to buy." => [ "x3" ]
  }.each do |text, claims|
    it "rejects the invented claim in #{text.inspect}" do
      expect(unsupported_in(text)).to eq(claims)
    end
  end

  it "accepts a percentage that is part of a given name (99% Invisible, 1% for the Planet)" do
    allowed = described_class.add_texts(described_class::Allowed.empty, "99% Invisible", "1% for the Planet")
    expect(described_class.unsupported("Heard on 99% Invisible; a 1% for the Planet member.", allowed)).to eq([])
    expect(described_class.unsupported("40% of fans", allowed)).to eq([ "40%" ])
  end

  it "accepts a percentage in the show's own title in a reason" do
    show.update!(title: "99% Invisible")
    expect(unsupported_in("Heard on 99% Invisible.")).to eq([])
  end

  it "accepts a magnitude-style token when it is the brand's own name (3M)" do
    expect(unsupported_in("3M fans share your audience's tastes.", scored(name: "3M"))).to eq([])
  end

  it "rejects an invented percentage" do
    expect(unsupported_in("40% of your listeners buy Ramp.")).to eq([ "40%" ])
  end

  it "accepts the shared-tag count" do
    expect(unsupported_in("Shares 6 taste tags with your audience.")).to eq([])
  end

  it "rejects a shared-tag count that isn't the stored one" do
    expect(unsupported_in("Shares 8 taste tags with your audience.")).to eq([ "8" ])
  end

  it "accepts age-bucket ranges" do
    expect(unsupported_in("Fans lean 25–34, like your audience.")).to eq([])
  end

  it "accepts an episode number from the show's feed titles" do
    expect(unsupported_in("A natural fit for Ep. 112's pricing talk.")).to eq([])
  end

  it "accepts digits in the brand name" do
    expect(unsupported_in("7-Eleven fans share your audience's tastes.", scored(name: "7-Eleven"))).to eq([])
  end

  it "accepts the fit score, affinity, proven count, evidence dates and downloads" do
    text = "Fit 79, affinity 0.82 (82%), 3 sponsor reads, latest Sep 14 2026, for a 1,500-download show."
    expect(unsupported_in(text)).to eq([])
  end

  it "builds a summary allowlist from the saved matches and the profile" do
    match = scored
    toolkit.add_candidates([ match ])
    report.sponsor_matches.create!(show: show, brand_entity_id: match.candidate.entity.id, name: "Ramp", fit_score: 79, tier: "easy_yes", position: 1)
    claims = described_class.new(toolkit)
    allowed = claims.for_summary

    expect(claims.unsupported("We ranked 1 sponsor: 1 easy yes; Ramp fits at 79.", allowed)).to eq([])
    expect(claims.unsupported("Reach 10,000 listeners.", allowed)).to eq([ "10,000" ])
  end
end
