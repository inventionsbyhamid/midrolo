require "rails_helper"

# The promo banner's sign-in guard on the app layout (R63): a signed-out visitor never sees it, even while the promo
# runs. Every page on this layout is behind sign-in, so the layout is rendered directly.
RSpec.describe "layouts/app" do
  let(:plan_resolved) { [] }

  before do
    AppSettings.set(:promo_pro_until, 1.week.from_now.to_date.to_s)
    without_partial_double_verification do
      allow(view).to receive(:current_plan) { plan_resolved << true && Entitlements::Plan.new(:promo) }
    end
  end

  def render_layout(signed_in:)
    without_partial_double_verification { allow(view).to receive(:user_signed_in?).and_return(signed_in) }
    render
  end

  it "shows a signed-out visitor no promo banner, without resolving a plan" do
    render_layout(signed_in: false)
    expect(rendered).to include('id="main"')
    expect(rendered).not_to include("promo-banner", "Free Pro access")
    expect(plan_resolved).to be_empty
  end

  it "shows it to a signed-in user on the promo" do
    render_layout(signed_in: true)
    expect(Nokogiri::HTML(rendered).at_css(".promo-banner").text.squish)
      .to eq("Free Pro access during the Qloo hackathon judging — through #{Entitlements.promo_until.strftime('%b %-d')}.")
  end
end
