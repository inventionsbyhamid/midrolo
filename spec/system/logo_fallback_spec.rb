require "rails_helper"

# Remote logos sit over initials; one that fails to load is removed by logo_controller (no inline onerror, so a
# strict CSP can't break it). Port 1 on localhost refuses the connection, so this needs no network.
RSpec.describe "Logo fallback" do
  include Warden::Test::Helpers

  it "shows the initials when a brand logo fails to load" do
    user = create(:user)
    show = create(:show, user: user)
    report = create(:report, show: show, kind: "agent", status: "done")
    create(:sponsor_match, report: report, name: "Fieldnote Coffee", image_url: "http://127.0.0.1:1/logo.png")
    login_as(user, scope: :user)

    visit show_report_path(show, report)

    within("[data-filter-target='item']") do
      expect(page).to have_no_css("img", visible: :all, wait: 10)
      expect(page).to have_css(".avatar", text: "FC")
    end
  end
end
