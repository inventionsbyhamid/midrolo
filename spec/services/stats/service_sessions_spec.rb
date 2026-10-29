require "rails_helper"

RSpec.describe Stats::ServiceSessions do
  it "saves only the platform's keys, stripped, as working" do
    session = described_class.save!("spotify", { "sp_dc" => "  cookie  ", "sp_key" => "", "evil" => "x" },
                                    expires_hint: Time.utc(2027, 1, 1))
    expect(JSON.parse(session.credentials)).to eq("sp_dc" => "cookie")
    expect(session).to have_attributes(status: "ok", last_error: nil, expires_hint: Time.utc(2027, 1, 1))
  end

  it "replaces an expired session and makes it work again" do
    create(:service_session, platform: "apple", status: "expired", last_error: "Sign in again")
    described_class.save!("apple", { "myacinfo" => "a", "itctx" => "b" })
    expect(ServiceSession.find_by!(platform: "apple")).to have_attributes(status: "ok", last_error: nil)
  end

  it "refuses what can't be a session, without quoting it" do
    expect { described_class.save!("apple", { "myacinfo" => "only-one" }) }
      .to raise_error(described_class::Invalid, "Paste itctx to save the Apple Podcasts session.")
    expect { described_class.save!("spotify", { "sp_dc" => "has space" }) }.to raise_error(described_class::Invalid, /without spaces/)
    expect { described_class.save!("spotify", { "sp_dc" => "x" * 5000 }) }.to raise_error(described_class::Invalid, /too long/)
    expect { described_class.save!("youtube", {}) }.to raise_error(described_class::Invalid)
    expect(ServiceSession.count).to eq(0)
  end

  it "marks a session expired once, and mails the admins once" do
    session = create(:service_session, platform: "spotify")
    expect { described_class.expired!(session, "Sign in again") }.to have_enqueued_mail(AdminMailer, :service_session_expired)
    expect { described_class.expired!(session, "Sign in again") }.not_to have_enqueued_mail(AdminMailer, :service_session_expired)
    expect(session.reload).to have_attributes(status: "expired", last_error: "Sign in again")
    expect(described_class.working_platforms).to eq([])
  end
end
