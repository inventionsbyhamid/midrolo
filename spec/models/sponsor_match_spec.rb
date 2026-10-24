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

  describe ".carry_forward! (R46a)" do
    # Reports made in order, each newer than the last, as re-runs are.
    def report_on(show = self.show, kind: "agent", status: "done") = create(:report, show: show, kind: kind, status: status)

    def copy(report, brand = "b1", **attributes) = create(:sponsor_match, report: report, brand_entity_id: brand, **attributes)

    it "keeps pitched and its notes for the same brand on the new report" do
      copy(old_report, "b-ledger", status: "pitched", notes: "Emailed Sam on Oct 20")
      target = copy(new_report, "b-ledger")

      described_class.carry_forward!(new_report)

      expect(target.reload).to have_attributes(status: "pitched", notes: "Emailed Sam on Oct 20")
    end

    it "copies status, notes and follow-up date as a unit from the newest earlier copy" do
      first = report_on
      second = report_on
      copy(first, status: "pitched", notes: "First pitch", follow_up_on: Date.new(2026, 11, 2))
      copy(second, status: "replied", notes: "They replied", follow_up_on: nil)
      target = copy(report_on(status: "running"))

      described_class.carry_forward!(target.report)

      expect(target.reload).to have_attributes(status: "replied", notes: "They replied", follow_up_on: nil)
    end

    it "keeps a note the podcaster cleared on the newest copy cleared" do
      first = report_on
      second = report_on
      copy(first, status: "pitched", notes: "Old note")
      copy(second, status: "pitched", notes: nil)
      target = copy(report_on(status: "running"))

      described_class.carry_forward!(target.report)

      expect(target.reload).to have_attributes(status: "pitched", notes: nil)
    end

    it "keeps a brand set back to suggested suggested" do
      first = report_on
      second = report_on
      copy(first, status: "pitched", notes: "Old note")
      copy(second, status: "suggested")
      target = copy(report_on(status: "running"))

      described_class.carry_forward!(target.report)

      expect(target.reload).to have_attributes(status: "suggested", notes: nil)
    end

    it "carries a brand missing from the previous report but present two reports back" do
      first = report_on
      second = report_on
      copy(first, status: "won", notes: "Signed")
      copy(second, "other-brand")
      target = copy(report_on(status: "running"))

      described_class.carry_forward!(target.report)

      expect(target.reload).to have_attributes(status: "won", notes: "Signed")
    end

    it "skips a suggested copy on an earlier report that never finished" do
      first = report_on
      failed = report_on(status: "failed")
      copy(first, status: "pitched")
      copy(failed, status: "suggested")
      target = copy(report_on(status: "running"))

      described_class.carry_forward!(target.report)

      expect(target.reload.status).to eq("pitched")
    end

    it "leaves a match the podcaster already changed alone" do
      copy(old_report, status: "pitched", notes: "Old note", follow_up_on: Date.new(2026, 11, 2))
      target = copy(new_report, notes: "Mine")

      described_class.carry_forward!(new_report)

      expect(target.reload).to have_attributes(status: "suggested", notes: "Mine", follow_up_on: nil)
    end

    it "matches by brand and leaves other brands alone" do
      copy(old_report, "b1", status: "pitched")
      other = copy(new_report, "b2")

      expect { described_class.carry_forward!(new_report) }.not_to change(described_class, :count)
      expect(other.reload.status).to eq("suggested")
    end

    it "is idempotent" do
      copy(old_report, status: "replied", notes: "They said yes to a call")
      target = copy(new_report)

      2.times { described_class.carry_forward!(new_report) }

      expect(target.reload).to have_attributes(status: "replied", notes: "They said yes to a call")
    end

    context "with a Snapshot the plan limits to 1 visible match (R43)" do
      before { stub_plan(visible_matches_limit: 1) }

      it "gives a locked match nothing, so its brand can't reach the pipeline" do
        copy(old_report, "b1", status: "pitched")
        copy(old_report, "b2", status: "won")
        snapshot = report_on(kind: "snapshot", status: "running")
        visible = copy(snapshot, "b1", position: 1)
        locked = copy(snapshot, "b2", position: 2)

        described_class.carry_forward!(snapshot)

        expect(visible.reload.status).to eq("pitched")
        expect(locked.reload.status).to eq("suggested")
      end

      it "never takes a locked copy as the source; a visible older copy wins" do
        copy(old_report, "b1", status: "pitched", notes: "Visible copy")
        snapshot = report_on(kind: "snapshot")
        copy(snapshot, "b0", position: 1)
        copy(snapshot, "b1", position: 2, status: "won", notes: "Locked copy")
        target = copy(report_on(status: "running"), "b1")

        described_class.carry_forward!(target.report)

        expect(target.reload).to have_attributes(status: "pitched", notes: "Visible copy")
      end
    end
  end

  describe "#follow_up_alert" do
    around { |example| travel_to(Date.new(2026, 10, 25)) { example.run } }

    it "flags an open deal's follow-up due today or overdue, never a won or lost one" do
      expect(build(:sponsor_match, status: "pitched", follow_up_on: Date.new(2026, 10, 25)).follow_up_alert).to eq(:today)
      expect(build(:sponsor_match, status: "saved", follow_up_on: Date.new(2026, 10, 1)).follow_up_alert).to eq(:overdue)
      expect(build(:sponsor_match, status: "pitched", follow_up_on: Date.new(2026, 10, 30)).follow_up_alert).to be_nil
      expect(build(:sponsor_match, status: "won", follow_up_on: Date.new(2026, 10, 1)).follow_up_alert).to be_nil
      expect(build(:sponsor_match, status: "lost", follow_up_on: Date.new(2026, 10, 25)).follow_up_alert).to be_nil
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

    it "breaks a position tie by id, the order the report lists them in" do
      snapshot = create(:report, show: show, kind: "snapshot", status: "done")
      matches = Array.new(3) { create(:sponsor_match, report: snapshot, position: 1) }

      expect(matches.map { |match| match.locked?(plan) }).to eq([ false, false, true ])
      expect(snapshot.sponsor_matches.to_a).to eq(matches)
    end

    it "never locks a match on an agent report (R44)" do
      matches = (1..3).map { |position| create(:sponsor_match, report: old_report, position: position) }

      expect(matches.map { |match| match.locked?(plan) }).to all(be(false))
    end
  end
end
