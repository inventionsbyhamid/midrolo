require "rails_helper"

# Why the plan said no, and the next step, for each Entitlements::NotAllowed reason (R63, R63a). The prompt shows the
# details captured when the plan refused (NotAllowed#details), so its numbers don't drift after a redirect.
RSpec.describe "shared/_upgrade_prompt" do
  def render_prompt(**prompt)
    render(partial: "shared/upgrade_prompt", locals: { prompt: prompt })
    Nokogiri::HTML5.fragment(rendered).at_css(".upgrade-prompt")
  end

  def limit_prompt(kind: :agent, used: 4, in_flight: 0, limit: 4, period: "billing period", bucket: :paid)
    render_prompt(reason: :limit, kind: kind, used: used, in_flight: in_flight, limit: limit, period: period, bucket: bucket)
  end

  def link(node) = node.at_css("a") && [ node.at_css("a").text, node.at_css("a")["href"] ]

  describe ":limit" do
    it "counts this period's work, with a link to the plans" do
      node = limit_prompt
      expect(node.text.squish).to eq("You've used 4 of 4 reports this billing period See plans")
      expect(link(node)).to eq([ "See plans", "/pricing" ])
      expect(limit_prompt(kind: :pitch, used: 20, limit: 20, period: "month", bucket: :promo).text.squish)
        .to start_with("You've used 20 of 20 pitches this month")
    end

    it "names the noun by the limit" do
      expect(limit_prompt(used: 1, limit: 1, period: nil, bucket: :promo).text.squish).to start_with("You've used 1 of 1 report See")
      expect(limit_prompt(kind: :snapshot, used: 1, limit: 1, period: "month", bucket: nil).text.squish)
        .to start_with("You've used 1 of 1 Snapshot this month")
    end

    it "says how much more is in progress, so it agrees with the done counts on the account page" do
      expect(limit_prompt(used: 3, in_flight: 1).text.squish)
        .to start_with("You've used 3 of 4 reports this billing period, and 1 more is in progress")
      expect(limit_prompt(used: 2, in_flight: 2).text.squish)
        .to start_with("You've used 2 of 4 reports this billing period, and 2 more are in progress")
    end
  end

  describe ":budget (R63a)" do
    it "sends a promo user to the waitlist once the promo pool is spent" do
      node = render_prompt(reason: :budget, kind: :agent, bucket: :promo)
      expect(node.text.squish).to eq("Full reports are paused for now — join the waitlist Join the waitlist")
      expect(link(node)).to eq([ "Join the waitlist", "/pricing" ])
      expect(render_prompt(reason: :budget, kind: :pitch, bucket: :promo).text.squish)
        .to start_with("Pitch packs are paused for now — join the waitlist")
    end

    it "tells a paying user it's today's capacity, never to join a waitlist" do
      node = render_prompt(reason: :budget, kind: :agent, bucket: :paid)
      expect(node.text.squish)
        .to eq("We've hit today's capacity for full reports — try again tomorrow. This didn't use any of your quota.")
      expect(node.at_css("a")).to be_nil
      expect(render_prompt(reason: :budget, kind: :pitch, bucket: :paid).text.squish)
        .to eq("We've hit today's capacity for pitch packs — try again tomorrow. This didn't use any of your quota.")
    end

    it "tells a judge whose reserve is spent the same" do
      node = render_prompt(reason: :budget, kind: :agent, bucket: :judge)
      expect(node.text.squish)
        .to eq("We've hit today's capacity for full reports — try again tomorrow. This didn't use any of your quota.")
      expect(node.text).not_to include("waitlist")
    end
  end

  it "gives the pause's reason, or a default, with no link" do
    AppSettings.set(:runs_paused_reason, "Back after a short maintenance break.")
    expect(render_prompt(reason: :paused, kind: :agent, bucket: :paid).text.squish).to eq("Back after a short maintenance break.")
    AppSettings.set(:runs_paused_reason, nil)
    node = render_prompt(reason: :paused, kind: :snapshot, bucket: nil)
    expect(node.text.squish).to eq(PlansHelper::PAUSED_MESSAGE)
    expect(node.at_css("a")).to be_nil
  end

  it "points a plan without full reports or pitch packs to Creator" do
    node = render_prompt(reason: :plan, kind: :agent, bucket: nil)
    expect(node.text.squish).to eq("Full agent reports are on Creator and up See plans")
    expect(link(node)).to eq([ "See plans", "/pricing" ])
    expect(render_prompt(reason: :plan, kind: :pitch, bucket: nil).text.squish).to start_with("Pitch packs are on Creator and up Each one is")
  end
end
