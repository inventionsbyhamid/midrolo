require "rails_helper"

RSpec.describe SponsorMatch do
  let(:show) { create(:show) }
  let(:old_report) { create(:report, show: show, kind: "agent", status: "done") }
  let(:new_report) { create(:report, show: show, kind: "agent", status: "running") }

  describe "validations" do
    subject(:match) { build(:sponsor_match) }

    it "caps the length of notes" do
      match.notes = "a" * SponsorMatch::NOTES_LIMIT
      expect(match).to be_valid
      match.notes = "a" * (SponsorMatch::NOTES_LIMIT + 1)
      expect(match).not_to be_valid
      expect(match.errors[:notes]).to be_present
    end

    it "stores blank notes as nil and trims the rest" do
      match.notes = "   \n "
      expect(match.notes).to be_nil
      match.notes = "  Emailed Sam  "
      expect(match.notes).to eq("Emailed Sam")
    end

    it "rejects a follow-up date that isn't a date instead of silently dropping it" do
      match.follow_up_on = "2026-13-45"
      expect(match).not_to be_valid
      expect(match.errors.full_messages_for(:follow_up_on)).to eq([ "Follow-up date isn't a valid date" ])
    end

    it "rejects a follow-up date in an implausible year (a half-typed year like 0002)" do
      match.follow_up_on = "0002-10-30"
      expect(match).not_to be_valid
      match.follow_up_on = "2026-10-30"
      expect(match).to be_valid
    end

    it "allows clearing the follow-up date" do
      match.follow_up_on = ""
      expect(match).to be_valid
      expect(match.follow_up_on).to be_nil
    end

    it "rejects an unknown status as a validation error" do
      match.status = "bogus"
      expect(match).not_to be_valid
      expect(match.errors[:status]).to be_present
    end
  end

  describe ".carry_forward!" do
    it "keeps pitched and its notes for the same brand on the new report" do
      create(:sponsor_match, report: old_report, brand_entity_id: "b-ledger", status: "pitched", notes: "Emailed Sam on Oct 20")
      target = create(:sponsor_match, report: new_report, brand_entity_id: "b-ledger")

      described_class.carry_forward!(old_report, new_report)

      expect(target.reload).to have_attributes(status: "pitched", notes: "Emailed Sam on Oct 20")
    end

    it "carries the follow-up date" do
      create(:sponsor_match, report: old_report, brand_entity_id: "b1", status: "saved", follow_up_on: Date.new(2026, 11, 2))
      target = create(:sponsor_match, report: new_report, brand_entity_id: "b1")

      described_class.carry_forward!(old_report, new_report)

      expect(target.reload.follow_up_on).to eq(Date.new(2026, 11, 2))
    end

    it "copies only the fields set on the source" do
      create(:sponsor_match, report: old_report, brand_entity_id: "b1", status: "suggested", notes: "Maybe in spring")
      target = create(:sponsor_match, report: new_report, brand_entity_id: "b1")

      described_class.carry_forward!(old_report, new_report)

      expect(target.reload).to have_attributes(status: "suggested", notes: "Maybe in spring", follow_up_on: nil)
    end

    it "never overwrites a field already set on the target" do
      create(:sponsor_match, report: old_report, brand_entity_id: "b1", status: "pitched", notes: "Old note",
                             follow_up_on: Date.new(2026, 11, 2))
      target = create(:sponsor_match, report: new_report, brand_entity_id: "b1", status: "won", notes: "Signed!",
                                      follow_up_on: nil)

      described_class.carry_forward!(old_report, new_report)

      expect(target.reload).to have_attributes(status: "won", notes: "Signed!", follow_up_on: Date.new(2026, 11, 2))
    end

    it "matches by brand and leaves other brands alone" do
      create(:sponsor_match, report: old_report, brand_entity_id: "b1", status: "pitched")
      create(:sponsor_match, report: old_report, brand_entity_id: "gone", status: "won")
      other = create(:sponsor_match, report: new_report, brand_entity_id: "b2")

      expect { described_class.carry_forward!(old_report, new_report) }.not_to change(described_class, :count)
      expect(other.reload.status).to eq("suggested")
    end

    it "is idempotent" do
      create(:sponsor_match, report: old_report, brand_entity_id: "b1", status: "replied", notes: "They said yes to a call")
      target = create(:sponsor_match, report: new_report, brand_entity_id: "b1")

      2.times { described_class.carry_forward!(old_report, new_report) }

      expect(target.reload).to have_attributes(status: "replied", notes: "They said yes to a call")
    end

    it "does nothing when the earlier report has no tracked matches" do
      create(:sponsor_match, report: old_report, brand_entity_id: "b1")
      target = create(:sponsor_match, report: new_report, brand_entity_id: "b1")

      expect { described_class.carry_forward!(old_report, new_report) }.not_to(change { target.reload.updated_at })
    end
  end

  describe "#follow_up_state" do
    around { |example| travel_to(Date.new(2026, 10, 25)) { example.run } }

    it "is overdue, today or upcoming against Date.current, and nil with no date" do
      expect(build(:sponsor_match, follow_up_on: Date.new(2026, 10, 24)).follow_up_state).to eq(:overdue)
      expect(build(:sponsor_match, follow_up_on: Date.new(2026, 10, 25)).follow_up_state).to eq(:today)
      expect(build(:sponsor_match, follow_up_on: Date.new(2026, 10, 26)).follow_up_state).to eq(:upcoming)
      expect(build(:sponsor_match, follow_up_on: nil).follow_up_state).to be_nil
    end
  end

  describe "#locked?" do
    let(:plan) { instance_double(Entitlements::Plan, visible_matches_limit: 2) }

    it "locks a Snapshot match beyond the plan's visible limit, by position" do
      snapshot = create(:report, show: show, kind: "snapshot", status: "done")
      matches = [ 3, 1, 2 ].map { |position| create(:sponsor_match, report: snapshot, position: position) }

      expect(matches.map { |match| match.locked?(plan) }).to eq([ true, false, false ])
    end

    it "never locks a match on an agent report (R44)" do
      matches = (1..3).map { |position| create(:sponsor_match, report: old_report, position: position) }

      expect(matches.map { |match| match.locked?(plan) }).to all(be(false))
    end
  end
end
