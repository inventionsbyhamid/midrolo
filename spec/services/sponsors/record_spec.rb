require "rails_helper"

RSpec.describe Sponsors::Record do
  let(:podcast) { create(:podcast, :active) }
  let(:episode) { create(:episode, podcast: podcast, published_at: Time.zone.parse("2026-09-14 10:00")) }

  def detection(name, domain: nil, by: "pattern", **fields)
    Sponsors::Scan::Detection.new(**{ episode: episode, name: name, domain: domain, url: nil, promo_code: nil, offer: nil,
                                      evidence: "Brought to you by #{name}.", detected_by: by, confidence: 0.9 }.merge(fields))
  end

  def result(detections, checked: [], scanned: [ episode.id ], settled: [])
    Sponsors::Scan::Result.new(detections: detections, checked_episode_ids: checked, settled_episode_ids: settled,
                               scanned_episode_ids: scanned, stage2: :done)
  end

  it "resolves each brand, saves one mention per episode and brand with the episode's date, and marks the episode" do
    notion = create(:brand, name: "Notion", domain: "notion.so")

    written = described_class.call(podcast, result([ detection("Notion Labs", domain: "notion.so", promo_code: "LEX"),
                                                     detection("Mercury"), detection("mercury") ]))

    expect(written).to eq(2)
    mercury = Brand.find_by!(name_key: "mercury")
    expect(SponsorMention.where(episode: episode).pluck(:brand_id)).to contain_exactly(notion.id, mercury.id)
    expect(SponsorMention.find_by!(brand: notion)).to have_attributes(podcast_id: podcast.id, promo_code: "LEX", detected_by: "pattern",
                                                                      published_at: episode.published_at, confidence: 0.9)
    expect([ notion.reload.sponsor_mentions_count, mercury.reload.sponsor_mentions_count ]).to eq([ 1, 1 ])
    expect(episode.reload.sponsor_scanned_at).to be_present
  end

  it "marks the episodes the AI-first scan settled as checked, and the others only as read" do
    short = create(:episode, podcast: podcast)
    read = create(:episode, podcast: podcast)

    described_class.call(podcast, result([], checked: [ episode.id ], settled: [ episode.id, short.id ],
                                             scanned: [ episode.id, short.id, read.id ]))

    expect([ episode, short ].map(&:reload)).to all(have_attributes(sponsor_ai_checked_at: be_present, sponsor_scanned_at: be_present))
    expect(read.reload).to have_attributes(sponsor_ai_checked_at: nil, sponsor_scanned_at: be_present)
  end

  it "replaces an episode's pattern reads with the model's answer, one row per brand" do
    notion = create(:brand, name: "Notion", domain: "notion.so")
    create(:sponsor_mention, episode: episode, podcast: podcast, brand: notion, detected_by: "pattern")
    create(:sponsor_mention, episode: episode, podcast: podcast, brand: create(:brand, name: "Mercury"), detected_by: "pattern")

    described_class.call(podcast, result([ detection("Notion", domain: "notion.so", by: "llm") ], checked: [ episode.id ],
                                         settled: [ episode.id ]))

    expect(SponsorMention.where(episode: episode).pluck(:brand_id, :detected_by)).to eq([ [ notion.id, "llm" ] ])
    expect(notion.reload.sponsor_mentions_count).to eq(1)
  end

  it "gives a new brand the model's proper name and never renames an existing one" do
    create(:brand, name: "Notion Labs", domain: "notion.so")

    described_class.call(podcast, result([ detection("Cellercise", domain: "cellercise.com", by: "llm"),
                                           detection("Notion", domain: "notion.so", by: "llm") ], checked: [ episode.id ]))

    expect(Brand.find_by!(domain: "cellercise.com").name).to eq("Cellercise")
    expect(Brand.find_by!(domain: "notion.so").name).to eq("Notion Labs")
  end

  it "names a brand after its domain until a real name comes" do
    described_class.call(podcast, result([ detection("manscaped.com", domain: "manscaped.com") ]))
    brand = Brand.find_by!(domain: "manscaped.com")
    expect(brand.name).to eq("manscaped.com")

    other = create(:episode, podcast: podcast)
    described_class.call(podcast, result([ detection("Manscaped", domain: "manscaped.com", episode: other) ], scanned: [ other.id ]))
    expect(brand.reload).to have_attributes(name: "Manscaped", sponsor_mentions_count: 2)
  end

  # C1: anyone can add a feed, so its show notes must never give an existing brand a domain (which a work email at it
  # would then verify into) or another name.
  it "never gives a brand a domain or a new name from a feed" do
    acme = create(:brand, name: "Acme", domain: nil)
    create(:brand_member, brand: acme, verified_at: Time.current)
    manscaped = create(:brand, name: "manscaped.com", domain: "manscaped.com")

    described_class.call(podcast, result([ detection("Acme", domain: "evil.example"), detection("Totally Legit", domain: "manscaped.com") ]))

    expect(acme.reload).to have_attributes(name: "Acme", domain: nil)
    expect(manscaped.reload.name).to eq("manscaped.com")
    expect(SponsorMention.where(episode: episode).map { |m| m.brand.domain }).to contain_exactly("evil.example", "manscaped.com")
    expect(Brand.find_by!(domain: "evil.example")).to have_attributes(name: "Acme", sponsor_mentions_count: 1)
  end

  it "replaces a checked episode's mentions, but only adds to an episode the patterns alone read" do
    old = create(:sponsor_mention, episode: episode, podcast: podcast, brand: create(:brand, name: "Gone"), detected_by: "llm")
    kept = create(:sponsor_mention, episode: create(:episode, podcast: podcast), podcast: podcast, brand: create(:brand, name: "Kept"))
    other = kept.episode

    described_class.call(podcast, result([ detection("Fresh", by: "llm"), detection("Newer", episode: other) ],
                                         checked: [ episode.id ], scanned: [ episode.id, other.id ]))

    expect(SponsorMention.where(episode: episode).map { |m| m.brand.name }).to eq([ "Fresh" ])
    expect(SponsorMention.where(episode: other).map { |m| m.brand.name }).to contain_exactly("Kept", "Newer")
    expect(old.brand.reload.sponsor_mentions_count).to eq(0)
  end

  it "writes the same rows when run twice, and touches the podcast only when something changed" do
    run = -> { described_class.call(podcast, result([ detection("Notion", domain: "notion.so") ])) }
    run.call
    podcast.update_column(:updated_at, 1.day.ago)

    expect { expect(run.call).to eq(0) }.not_to change(SponsorMention, :count)
    expect(podcast.reload.updated_at).to be < 1.hour.ago
    expect(Brand.find_by!(domain: "notion.so").sponsor_mentions_count).to eq(1)
  end

  it "touches the podcast when mentions are added" do
    podcast.update_column(:updated_at, 1.day.ago)
    described_class.call(podcast, result([ detection("Notion") ]))
    expect(podcast.reload.updated_at).to be > 1.minute.ago
  end

  it "merges two detections that resolve to one brand, keeping every field either had" do
    described_class.call(podcast, result([ detection("AG1", domain: "drinkag1.com", url: "https://drinkag1.com/tim"),
                                           detection("ag1", domain: "drinkag1.com", promo_code: "TIM", confidence: 0.95) ]))

    expect(SponsorMention.sole).to have_attributes(url: "https://drinkag1.com/tim", promo_code: "TIM", confidence: 0.95)
  end

  it "skips a detection with no brand to make" do
    allow(Rails.error).to receive(:report)
    expect(described_class.call(podcast, result([ detection(" ") ]))).to eq(0)
    expect(Rails.error).to have_received(:report).with(an_instance_of(ArgumentError), hash_including(handled: true))
  end
end
