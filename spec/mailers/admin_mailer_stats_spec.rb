require "rails_helper"

RSpec.describe AdminMailer do
  it "tells the admins a service session expired, with the page to fix it and no cookie" do
    create(:user, admin: true, email: "ops@example.com")
    create(:service_session, platform: "spotify", credentials: { "sp_dc" => "secret-cookie-value" }.to_json)
    mail = described_class.service_session_expired(platform: "spotify")

    expect(mail.to).to eq([ "ops@example.com" ])
    expect(mail.subject).to include("Spotify for Creators session expired")
    expect(mail.body.to_s).to include("http://example.com/admin/service_sessions").and include("syncs are paused")
    expect(mail.body.to_s).not_to include("secret-cookie-value")
  end
end
