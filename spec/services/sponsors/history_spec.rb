require "rails_helper"

RSpec.describe Sponsors::History do
  let(:podcast) { create(:podcast, :active) }
  let(:notion) { create(:brand, name: "Notion", domain: "notion.so") }
  let(:ramp) { create(:brand, name: "Ramp", domain: "ramp.com") }

  def read(brand, on:, at:, code: nil, evidence: nil, offer: nil, show: podcast)
    episode = create(:episode, podcast: show, title: "Episode at #{at.to_date}", published_at: at)
    create(:sponsor_mention, episode: episode, podcast: show, brand: brand, published_at: at, promo_code: code,
                             evidence: evidence || "Brought to you by #{brand.name} on #{on}.", offer: offer)
  end

  def queries
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:sql].start_with?("BEGIN", "COMMIT", "SAVEPOINT", "RELEASE") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  describe ".for" do
    it "gives one row per brand, the most recent first, from one query" do
      read(notion, on: "a", at: Time.zone.parse("2026-03-02"), code: "OLD", offer: "Free plan")
      read(notion, on: "b", at: Time.zone.parse("2026-09-20"), code: "LEX")
      read(notion, on: "c", at: Time.zone.parse("2026-08-01"), code: "LEX")
      read(ramp, on: "d", at: Time.zone.parse("2026-10-01"), evidence: "Ramp saves you money.")

      rows = nil
      expect(queries { rows = described_class.for(podcast).to_a }).to eq(1)

      expect(rows.map(&:brand)).to eq([ ramp, notion ])
      row = rows.last
      expect(row).to have_attributes(podcast: podcast, podcast_id: podcast.id, brand_id: notion.id, episodes_count: 3,
                                     promo_codes: %w[LEX OLD], offer: "Free plan",
                                     evidence: "Brought to you by Notion on b.", evidence_episode_title: "Episode at 2026-09-20")
      expect(row.first_seen).to eq(Time.zone.parse("2026-03-02"))
      expect(row.last_seen).to eq(Time.zone.parse("2026-09-20"))
      expect(row.evidence_episode_slug).to eq(Episode.find_by!(title: "Episode at 2026-09-20").slug)
    end

    it "is empty for a podcast with no reads, or one not saved" do
      expect(described_class.for(podcast)).to eq([])
      expect(described_class.for(build(:podcast))).to eq([])
    end
  end

  describe ".for_brand and .for_brands" do
    let(:other) { create(:podcast, :active) }

    before do
      read(notion, on: "a", at: 2.months.ago)
      read(notion, on: "b", at: 3.days.ago, show: other)
      read(notion, on: "c", at: 2.days.ago, show: other)
      read(ramp, on: "d", at: 1.day.ago)
    end

    it "gives one row per podcast the brand sponsored, the most recent first, from one query" do
      rows = nil
      expect(queries { rows = described_class.for_brand(notion).to_a }).to eq(1)

      expect(rows.map { |row| [ row.podcast, row.episodes_count ] }).to eq([ [ other, 2 ], [ podcast, 1 ] ])
      expect(rows.map(&:brand)).to all(eq(notion))
    end

    it "leaves out removed podcasts" do
      other.update!(status: "removed")
      expect(described_class.for_brand(notion).map(&:podcast)).to eq([ podcast ])
    end

    it "gives rows for several brands at once" do
      rows = described_class.for_brands([ notion, ramp.id ])
      expect(rows.map { |row| [ row.brand_id, row.podcast_id ] }).to contain_exactly([ notion.id, other.id ], [ notion.id, podcast.id ],
                                                                                      [ ramp.id, podcast.id ])
      expect(rows.find { |row| row.brand_id == ramp.id }.brand).to be_nil
      expect(described_class.for_brands([])).to eq([])
    end

    it "reads as FitSearch::Proof expects" do
      proof = FitSearch::Proof.call([ [ notion, :competitor ] ])
      expect(proof[other.id]).to eq([ { "brand" => "Notion", "slug" => notion.slug, "relation" => "competitor", "episodes" => 2,
                                        "last_seen" => 2.days.ago.to_date.iso8601 } ])
    end
  end
end
