require "rails_helper"

# Request a spot mail: what each says, who gets it (the owner's account, never the feed's owner address), the low
# priority MailBudget reads, and no brand text in the body.
RSpec.describe ConversationMailer do
  let(:owner) { create(:user, email: "maya@example.com") }
  let(:podcast) { claimed_podcast(owner: owner, title: "The Founder's Ledger") }
  let(:asker) { create(:user, name: "Sam Rivera", email: "sam@fieldnote.example") }
  let(:brand) { create(:brand, name: "Fieldnote Coffee", domain: "fieldnote.example") }
  let(:membership) { brand_member_for(asker, brand: brand) }
  let(:month) { Date.current.next_month }
  let(:conversation) do
    start_request(podcast, membership, format: "midroll", months: [ month.strftime("%Y-%m") ], budget: "500",
                                       body: "Visit totally-legit.example for a prize")
  end

  def text(mail) = mail.text_part.body.to_s
  def html(mail) = mail.html_part.body.to_s
  def dash = /[—–]/

  describe "#new_request" do
    let(:mail) { described_class.with(conversation: conversation).new_request }

    it "tells the owner's account who asked for what, labels an unverified brand and links the thread" do
      expect(mail.to).to eq([ "maya@example.com" ])
      expect(mail.subject).to eq("Fieldnote Coffee asked about sponsoring The Founder's Ledger")
      expect(text(mail)).to include("Fieldnote Coffee would like to sponsor The Founder's Ledger",
                                    "Unverified brand",
                                    "a midroll in #{month.strftime('%b %Y')}, with a budget of $500",
                                    "/conversations/#{conversation.public_id}")
      expect(html(mail)).to include("data-mail-button")
      expect(mail[MailBudget::PRIORITY_HEADER].to_s).to eq("low")
    end

    it "never carries the brand's message, and has no dashes" do
      expect(text(mail) + html(mail)).not_to include("totally-legit")
      expect(text(mail) + html(mail)).not_to match(dash)
    end

    it "drops the label for a verified member" do
      membership.update!(verified_at: Time.current)
      expect(text(mail)).not_to include("Unverified")
    end

    it "sends nothing for a request that waits for the claim, whatever the feed lists" do
      waiting = start_request(create(:podcast, owner_email: "feed-owner@example.com"), membership)
      expect(described_class.with(conversation: waiting).new_request.message).to be_a(ActionMailer::Base::NullMail)
    end
  end

  describe "#new_reply" do
    it "tells the asker the show replied, without the reply" do
      message = conversation.messages.create!(user: owner, body: "Our rate is $400")
      mail = described_class.with(message: message).new_reply

      expect(mail.to).to eq([ "sam@fieldnote.example" ])
      expect(mail.subject).to eq("The Founder's Ledger replied to your request")
      expect(text(mail)).not_to include("$400")
    end

    it "tells the owner the brand wrote" do
      message = conversation.messages.create!(user: asker, body: "Any news?")
      mail = described_class.with(message: message).new_reply

      expect(mail.to).to eq([ "maya@example.com" ])
      expect(mail.subject).to eq("Fieldnote Coffee wrote about The Founder's Ledger")
    end
  end

  describe "#answered" do
    it "gives the asker the decline reason" do
      conversation.decline!(reason: "Booked through December.")
      mail = described_class.with(conversation: conversation).answered

      expect(mail.to).to eq([ "sam@fieldnote.example" ])
      expect(mail.subject).to eq("The Founder's Ledger declined your request")
      expect(text(mail)).to include("Their reason: Booked through December.")
    end

    it "says accepted" do
      conversation.accept!
      expect(described_class.with(conversation: conversation).answered.subject).to eq("The Founder's Ledger accepted your request")
    end
  end

  describe "#waiting_requests" do
    it "counts the brands that asked before the claim and links the workspace inbox" do
      unclaimed = create(:podcast, title: "Night Owls")
      start_request(unclaimed, membership)
      show = create(:show, user: owner, podcast: unclaimed)
      show.verify!(via: "email")

      mail = described_class.with(podcast: unclaimed.reload).waiting_requests
      expect(mail.to).to eq([ "maya@example.com" ])
      expect(mail.subject).to eq("A brand asked about sponsoring Night Owls")
      expect(text(mail)).to include("/shows/#{show.public_id}/inbox", "Nothing was sent to the address in your feed")
    end
  end

  describe "#reported" do
    it "goes to the admins" do
      create(:user, admin: true, email: "ops@example.com")
      mail = described_class.with(conversation: conversation).reported

      expect(mail.to).to eq([ "ops@example.com" ])
      expect(text(mail)).to include(conversation.public_id, "fieldnote.example")
    end
  end
end
