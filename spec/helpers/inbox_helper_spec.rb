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

  it "puts a request's budget next to the show's own rate for that spot (review IN-2, IN-3)" do
    podcast = claimed_podcast(owner: create(:user))
    MediaKit.find_or_initialize_by(show: podcast.owner_show).update!(published_at: Time.current, rate_card_overrides: { "midroll" => 180 })
    under = build(:conversation, podcast: podcast, format: "midroll", months: %w[2026-11], budget_cents: 12_000)
    over = build(:conversation, podcast: podcast, format: "midroll", budget_cents: 30_000)

    expect(helper.inbox_rate_check(under)).to eq(rate: "Your midroll: $180", note: "$60 under your rate", tone: :warning)
    expect(helper.inbox_rate_check(over)).to include(note: "At or above your rate", tone: :success)
    expect(helper.inbox_rate_check(build(:conversation, podcast: podcast, format: nil, budget_cents: 30_000))).to be_nil
    expect(helper.inbox_request_line(under)).to eq("Midroll, Nov 2026, $120 budget")
  end
end
