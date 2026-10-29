require "rails_helper"

# The promo banner's sign-in guard on the app layout (R63): a signed-out visitor never sees it, even while the promo
# runs. Every page on this layout is behind sign-in, so the layout is rendered directly.
RSpec.describe "layouts/app" do
  let(:plan_resolved) { [] }

  before do
    AppSettings.set(:promo_pro_until, 1.week.from_now.to_date.to_s)
    without_partial_double_verification do
      allow(view).to receive(:current_plan) { plan_resolved << true && Entitlements::Plan.new(:promo) }
      allow(view).to receive(:masquerading?).and_return(false)
    end
  end

  def render_layout(signed_in:)
    without_partial_double_verification do
      allow(view).to receive(:user_signed_in?).and_return(signed_in)
      allow(view).to receive(:current_user).and_return(signed_in ? create(:user) : nil)
    end
    render
  end

  it "shows a signed-out visitor no promo banner, without resolving a plan" do
    render_layout(signed_in: false)
    expect(rendered).to include('id="main"')
    expect(rendered).not_to include("promo-banner", "Free Pro trial")
    expect(plan_resolved).to be_empty
    expect(Nokogiri::HTML(rendered).css("nav[aria-label='Main'] a").map { |link| link.text.squish })
      .to eq([ "Podcasts", "For brands", "Pricing" ])
  end

  it "shows it to a signed-in user on the promo" do
    render_layout(signed_in: true)
    expect(Nokogiri::HTML(rendered).at_css(".promo-banner").text.squish)
      .to eq("Free Pro trial for the Qloo hackathon judging, through #{Entitlements.promo_until.strftime('%b %-d')}: up to 3 shows, each with a Snapshot and a full report.")
    expect(Nokogiri::HTML(rendered).css("nav[aria-label='Main'] a").map { |link| link.text.squish })
      .to eq([ "Podcasts", "Your shows", "Pipeline", "Inbox", "Account" ])
  end
end
