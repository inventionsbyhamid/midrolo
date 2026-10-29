require "rails_helper"

RSpec.describe InboxHelper do
  it "writes months and the ask in words" do
    conversation = build(:conversation, format: "postroll", months: %w[2026-12 2027-01], budget_cents: 75_000)

    expect(helper.inbox_month_label("2026-12")).to eq("Dec 2026")
    expect(helper.inbox_request_summary(conversation)).to eq("a postroll in Dec 2026 and Jan 2027, with a budget of $750")
    expect(helper.inbox_request_summary(build(:conversation, format: nil, months: [], budget_cents: nil))).to eq("a spot")
  end

  it "offers this month and the next five, plus any already chosen" do
    options = helper.inbox_month_options([ "2027-09" ], from: Date.new(2026, 11, 20))

    expect(options.map(&:last)).to eq(%w[2026-11 2026-12 2027-01 2027-02 2027-03 2027-04 2027-09])
    expect(options.first.first).to eq("Nov 2026")
  end

  it "counts what's unread for the user on both sides" do
    owner = create(:user)
    podcast = claimed_podcast(owner: owner)
    membership = brand_member_for
    start_request(podcast, membership)

    expect(helper.inbox_unread_count(owner)).to eq(1)
    expect(helper.inbox_unread_count(membership.user)).to eq(0)
    expect(helper.inbox_unread_count(nil)).to eq(0)
  end
end
