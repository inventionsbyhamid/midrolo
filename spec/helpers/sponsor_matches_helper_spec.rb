require "rails_helper"

RSpec.describe SponsorMatchesHelper do
  around { |example| travel_to(Date.new(2026, 10, 25)) { example.run } }

  def match_due(date) = build(:sponsor_match, status: "pitched", follow_up_on: date)

  describe "#follow_up_flag" do
    it "says today, overdue, or the date" do
      expect(helper.follow_up_flag(match_due(Date.new(2026, 10, 25)))).to eq("Follow up today")
      expect(helper.follow_up_flag(match_due(Date.new(2026, 10, 1)))).to eq("Follow-up overdue")
      expect(Nokogiri::HTML5.fragment(helper.follow_up_flag(match_due(Date.new(2026, 11, 2)))).text).to eq("Follow up Nov 2")
      expect(helper.follow_up_flag(match_due(nil))).to be_nil
    end

    it "gives a won or lost brand its date, never a due flag" do
      won = build(:sponsor_match, status: "won", follow_up_on: Date.new(2026, 10, 1))
      expect(Nokogiri::HTML5.fragment(helper.follow_up_flag(won)).text).to eq("Follow up Oct 1")
      expect(helper.follow_up_tone(won)).to eq(:neutral)
      expect(helper.follow_up_badge(build(:sponsor_match, status: "lost", follow_up_on: Date.new(2026, 10, 25)))).to be_nil
    end
  end

  describe "#follow_up_time" do
    it "adds the year only outside this one" do
      expect(helper.follow_up_time(Date.new(2026, 11, 2))).to eq('<time datetime="2026-11-02">Nov 2</time>')
      expect(helper.follow_up_time(Date.new(2027, 1, 5))).to eq('<time datetime="2027-01-05">Jan 5, 2027</time>')
    end
  end

  describe "#follow_up_badge" do
    it "flags only follow-ups due today or overdue" do
      expect(helper.follow_up_badge(match_due(Date.new(2026, 10, 25)))).to include("Due today", "badge-warning")
      expect(helper.follow_up_badge(match_due(Date.new(2026, 10, 24)))).to include("Overdue", "badge-danger")
      expect(helper.follow_up_badge(match_due(Date.new(2026, 10, 26)))).to be_nil
    end
  end

  describe "#pipeline_enabled_for?" do
    it "asks Entitlements once per user in a render" do
      user = build_stubbed(:user)
      allow(Entitlements).to receive(:for).with(user).and_return(instance_double(Entitlements::Plan, pipeline?: false))

      3.times { expect(helper.pipeline_enabled_for?(user)).to be(false) }
      expect(Entitlements).to have_received(:for).once
    end
  end
end
