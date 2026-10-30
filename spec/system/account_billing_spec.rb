require "rails_helper"

# The account page's plan and upgrade cards in a real browser: the monthly/yearly switch is CSS only (:has), so only a
# browser shows it working, and the tiles sit side by side on a wide screen and stack on a phone.
RSpec.describe "Account billing" do
  include Warden::Test::Helpers

  around { |example| Capybara.using_wait_time(10) { example.run } }
  after { Warden.test_reset! }

  let(:user) { create(:user, name: "Ada Lovelace") }

  def tile(plan) = find(".upgrade-tile[data-plan='#{plan}']")

  def tops = evaluate_script("[...document.querySelectorAll('.upgrade-tile')].map((t) => Math.round(t.getBoundingClientRect().top))")

  it "switches the tiles' prices and buttons between monthly and yearly" do
    login_as(user, scope: :user)
    with_billing_env { visit "/account" }

    expect(tile(:creator)).to have_css(".upgrade-tile-amount", exact_text: "$19")
    expect(tile(:creator)).to have_no_css("[data-interval='yearly']")
    expect(tile(:creator)).to have_css("[data-interval='monthly'] input[name=price_key][value=creator_monthly]", visible: :all)

    choose "Yearly", allow_label_click: true
    expect(tile(:creator)).to have_css(".upgrade-tile-amount", exact_text: "$190")
    expect(tile(:pro)).to have_css(".upgrade-tile-amount", exact_text: "$490")
    expect(tile(:creator)).to have_no_css("[data-interval='monthly']")
    expect(tile(:creator)).to have_css("[data-interval='yearly'] input[name=price_key][value=creator_yearly]", visible: :all)
    expect(tile(:sprint)).to have_css(".upgrade-tile-amount", exact_text: "$49") # the Sprint has no interval to switch

    page.driver.browser.keyboard.type(:left) # arrow keys move between the radios
    expect(tile(:creator)).to have_css(".upgrade-tile-amount", exact_text: "$19")
  end

  it "puts the tiles side by side on a wide screen and stacks them on a phone, readable either way", :aggregate_failures do
    login_as(user, scope: :user)
    create(:report, show: create(:show, user: user), kind: "snapshot", status: "done")

    { "1440" => [ 1440, 900 ], "375" => [ 375, 812 ] }.each do |width, (w, h)|
      page.driver.resize(w, h)
      with_billing_env { visit "/account" }
      expect(page).to have_css(".usage-bar .usage-seg-on")

      expect(tops.uniq.size).to eq(width == "1440" ? 1 : 3), "tiles at #{width}px: #{tops}"
      expect(horizontal_overflow).to eq(0), "/account scrolls sideways at #{width}px"
      expect(skipped_heading_levels).to be_empty, "/account at #{width}px skips #{skipped_heading_levels.join(', ')}"
      expect(contrast_failures).to be_empty, "/account at #{width}px: #{contrast_failures.join('; ')}"
    end
  end
end
