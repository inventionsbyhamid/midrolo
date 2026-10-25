require "rails_helper"

# layouts/_head is shared by every layout (app, application, marketing, kit, print).
RSpec.describe "layouts/_head" do
  it "turns off Turbo's hover prefetch, which spends the per-IP rate limit and runs page queries on hover (R80)" do
    render partial: "layouts/head"
    expect(Nokogiri::HTML(rendered).at_css("meta[name='turbo-prefetch']")["content"]).to eq("false")
  end
end
