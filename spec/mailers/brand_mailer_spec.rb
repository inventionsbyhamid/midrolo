require "rails_helper"

RSpec.describe BrandMailer do
  let(:member) do
    create(:brand_member, brand: create(:brand, name: "Fieldnote Coffee", domain: "fieldnote.example"),
                          code_sent_to: "ada@fieldnote.example", code_expires_at: 30.minutes.from_now)
  end

  it "carries the code in both parts, with no dashes in the copy" do
    mail = described_class.with(member: member, sent_to: "ada@fieldnote.example").work_email_code

    code = mail.text_part.body.to_s[/\b\d{6}\b/]
    expect(code).to be_present
    expect(mail.html_part.body.to_s).to include(code, "Fieldnote Coffee")
    expect(mail.body.encoded).not_to match(/[\u2014\u2013]/)
  end

  it "sends nothing once the member is verified or the code expired" do
    member.update!(verified_at: Time.current)
    expect(described_class.with(member: member, sent_to: "ada@fieldnote.example").work_email_code.message).to be_a(ActionMailer::Base::NullMail)

    member.update!(verified_at: nil, code_expires_at: 1.minute.ago)
    expect(described_class.with(member: member, sent_to: "ada@fieldnote.example").work_email_code.message).to be_a(ActionMailer::Base::NullMail)
  end
end
