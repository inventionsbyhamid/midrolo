require "rails_helper"

RSpec.describe VerificationMailer do
  let(:show) { create(:show, title: "The Founder's Ledger", owner_email: "jane@example.com") }
  let(:verification) do
    ShowVerification.create!(show: show, kind: "email", sent_to: "jane@example.com", expires_at: 30.minutes.from_now)
  end

  it "mails a fresh code to the owner address, in text and HTML, branded with the app name" do
    mail = described_class.with(verification: verification).code
    text = mail.text_part.body.to_s
    code = text[/\b\d{6}\b/]

    expect(mail.to).to eq([ "jane@example.com" ])
    expect(mail[:from].value).to eq("Midrolo <hello@midrolo.com>")
    expect(mail.subject).to eq("Your Midrolo code for The Founder's Ledger")
    expect(text).to include("The Founder's Ledger", "30 minutes", APP_NAME)
    expect(mail.html_part.body.to_s).to include(code, APP_NAME)
    expect(verification.reload.check_code(code)).to be(true)
  end

  it "sends from MAIL_FROM when it is set" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("MAIL_FROM", anything).and_return("Kits <kits@example.com>")

    expect(described_class.with(verification: verification).code[:from].value).to eq("Kits <kits@example.com>")
  end
end
