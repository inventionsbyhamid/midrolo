require "rails_helper"

RSpec.describe Brands::WorkEmail do
  include ActiveJob::TestHelper

  let(:brand) { create(:brand, name: "Fieldnote Coffee", domain: "fieldnote.example") }
  let(:member) { create(:brand_member, brand: brand) }

  def sent_code = ActionMailer::Base.deliveries.last.text_part.body.to_s[/\b\d{6}\b/]

  def request(address = "ada@fieldnote.example") = perform_enqueued_jobs { described_class.request_code!(member, address) }

  it "mails a 6-digit code to an address at the brand's domain, storing only its digest" do
    request(" Ada@Shop.Fieldnote.example ")

    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq([ "ada@shop.fieldnote.example" ])
    expect(mail.subject).to eq("Your Midrolo code for Fieldnote Coffee")
    expect(sent_code).to match(/\A\d{6}\z/)
    member.reload
    expect(member).to have_attributes(code_sent_to: "ada@shop.fieldnote.example", attempts: 0)
    expect(member.code_digest).to eq(described_class.digest(member.id, sent_code))
    expect(member.code_digest).not_to include(sent_code)
  end

  it "refuses addresses at other domains, free email, junk, and brands without a website" do
    expect { described_class.request_code!(member, "ada@elsewhere.example") }
      .to raise_error(described_class::Invalid, "Use an address at fieldnote.example, your brand's website.")
    expect { described_class.request_code!(member, "ada@gmail.com") }
      .to raise_error(described_class::Invalid, /Free email addresses can't verify a brand/)
    expect { described_class.request_code!(member, "not an email") }.to raise_error(described_class::Invalid, "Enter a work email address.")

    Brand.where(id: member.brand_id).update_all(domain: nil) # only an admin changes a domain (Brand: attr_readonly)
    member.brand.reload
    expect { described_class.request_code!(member, "ada@fieldnote.example") }.to raise_error(described_class::Invalid, /website/)
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "waits a minute between codes" do
    request
    expect { described_class.request_code!(member, "ada@fieldnote.example") }.to raise_error(described_class::Throttled)

    travel(61.seconds) { expect { request }.to change(ActionMailer::Base.deliveries, :size).by(1) }
  end

  it "verifies the member and the brand with the right code" do
    request
    expect(described_class.check_code(member, sent_code.insert(3, " "))).to eq(:verified)

    expect(member.reload).to have_attributes(code_digest: nil, code_expires_at: nil)
    expect(member.verified_at).to be_present
    expect(brand.reload.verified_at).to be_present
    expect(described_class.check_code(member, "000000")).to eq(:verified) # nothing left to guess
  end

  it "counts wrong codes and locks after five" do
    request
    wrong = sent_code == "000000" ? "111111" : "000000"

    4.times { expect(described_class.check_code(member, wrong)).to eq(:wrong_code) }
    expect(described_class.attempts_left(member.reload)).to eq(1)
    expect(described_class.check_code(member, wrong)).to eq(:locked)
    expect(described_class.check_code(member, sent_code)).to eq(:locked)
    expect(member.reload.verified_at).to be_nil
  end

  it "refuses an expired code" do
    request
    code = sent_code

    travel(31.minutes) { expect(described_class.check_code(member, code)).to eq(:expired) }
  end

  it "sends nothing for a request retired by a newer address before its mail went out" do
    described_class.request_code!(member, "ada@fieldnote.example")
    member.update!(code_sent_to: "bob@fieldnote.example")

    perform_enqueued_jobs
    expect(ActionMailer::Base.deliveries).to be_empty
  end
end
