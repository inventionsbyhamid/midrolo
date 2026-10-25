require "rails_helper"

# Why the plan said no, and the next step, for each Entitlements::NotAllowed reason (R63).
RSpec.describe "shared/_upgrade_prompt" do
  let(:user) { create(:user) }
  let(:show) { create(:show, user: user) }

  def prompt(reason, kind, plan = Entitlements.for(user))
    render(partial: "shared/upgrade_prompt", locals: { reason: reason, kind: kind, plan: plan })
    Nokogiri::HTML5.fragment(rendered).at_css(".upgrade-prompt")
  end

  def link(node) = node.at_css("a") && [ node.at_css("a").text, node.at_css("a")["href"] ]

  it "counts this billing period's reports on a subscription, with a link to the plans" do
    create(:subscription, user: user, plan: "creator")
    4.times { create(:report, show: show, kind: "agent", status: "done", spend_bucket: "paid") }
    node = prompt(:limit, :agent)
    expect(node.text.squish).to eq("You've used 4 of 4 reports this billing period See plans")
    expect(link(node)).to eq([ "See plans", "/pricing" ])
  end

  it "counts this month's Snapshots on the free plan" do
    create(:report, show: show, kind: "snapshot", status: "done")
    expect(prompt(:limit, :snapshot).text.squish).to start_with("You've used 1 of 1 Snapshots this month")
  end

  it "counts work still in flight as used" do
    create(:subscription, user: user, plan: "creator")
    3.times { create(:report, show: show, kind: "agent", status: "done", spend_bucket: "paid") }
    create(:report, show: create(:show, user: user), kind: "agent", status: "running", started_at: 1.minute.ago)
    expect(prompt(:limit, :agent).text.squish).to start_with("You've used 4 of 4 reports this billing period")
  end

  it "counts the promo's report in total, with no period" do
    AppSettings.set(:promo_pro_until, 1.week.from_now.to_date.to_s)
    create(:report, show: show, kind: "agent", status: "done", spend_bucket: "promo")
    expect(prompt(:limit, :agent).text.squish).to eq("You've used 1 of 1 reports See plans")
  end

  it "counts this month's pitches on the promo" do
    AppSettings.set(:promo_pro_until, 1.week.from_now.to_date.to_s)
    expect(prompt(:limit, :pitch).text.squish).to start_with("You've used 0 of 20 pitches this month")
  end

  it "sends a spent budget to the waitlist" do
    node = prompt(:budget, :agent)
    expect(node.text.squish).to eq("Full reports are paused for now — join the waitlist Join the waitlist")
    expect(link(node)).to eq([ "Join the waitlist", "/pricing" ])
    expect(prompt(:budget, :pitch).text.squish).to start_with("Pitch packs are paused for now — join the waitlist")
  end

  it "gives the pause's reason, or a default, with no link" do
    AppSettings.set(:runs_paused_reason, "Qloo authentication failing")
    expect(prompt(:paused, :agent).text.squish).to eq("Qloo authentication failing")
    AppSettings.set(:runs_paused_reason, nil)
    node = prompt(:paused, :snapshot)
    expect(node.text.squish).to eq(PlansHelper::PAUSED_MESSAGE)
    expect(node.at_css("a")).to be_nil
  end

  it "points a plan without full reports or pitch packs to Creator" do
    node = prompt(:plan, :agent)
    expect(node.text.squish).to eq("Full agent reports are on Creator and up See plans")
    expect(link(node)).to eq([ "See plans", "/pricing" ])
    expect(prompt(:plan, :pitch).text.squish).to start_with("Pitch packs are on Creator and up Each one is")
  end
end
