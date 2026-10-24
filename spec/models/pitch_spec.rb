require "rails_helper"

RSpec.describe Pitch do
  let(:match) { create(:sponsor_match) }

  it "starts queued and allows only known statuses" do
    expect(described_class.create!(sponsor_match: match)).to be_queued
    expect(described_class.new(sponsor_match: match, status: "sent")).not_to be_valid
  end

  it "counts only done pitches toward usage" do
    done = described_class.create!(sponsor_match: match, status: "done")
    described_class.create!(sponsor_match: match, status: "failed")
    described_class.create!(sponsor_match: match, status: "queued")
    expect(described_class.counted).to eq([ done ])
  end

  it "gives each match its newest pitch, and each user their pitches" do
    older = described_class.create!(sponsor_match: match, status: "failed", created_at: 2.minutes.ago)
    newer = described_class.create!(sponsor_match: match)
    described_class.create!(sponsor_match: create(:sponsor_match))

    expect(match.latest_pitch).to eq(newer)
    expect(match.show.user.pitches).to contain_exactly(older, newer)
  end

  it "treats a pitch queued for too long as dead: not in flight, shown as failed" do
    fresh = described_class.create!(sponsor_match: match)
    stale = described_class.create!(sponsor_match: create(:sponsor_match), created_at: (Pitch::STALE_AFTER + 1.minute).ago)
    described_class.create!(sponsor_match: create(:sponsor_match), status: "done")

    expect(fresh).to be_in_flight
    expect(stale).not_to be_in_flight
    expect(stale).to be_stale
    expect(described_class.in_flight).to eq([ fresh ])
  end

  it "allows only one queued pitch per match in the database (R53)" do
    described_class.create!(sponsor_match: match)
    described_class.create!(sponsor_match: match, status: "done")
    expect { described_class.create!(sponsor_match: match) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "counts the body's words" do
    expect(described_class.new(body: "Hi there,\n\nthree more words").word_count).to eq(5)
  end

  it "goes when its match is deleted, even by delete_all (a re-saved match list)" do
    described_class.create!(sponsor_match: match)
    expect { SponsorMatch.where(id: match.id).delete_all }.to change(described_class, :count).by(-1)
  end
end
