require "rails_helper"

RSpec.describe ClaimMailer do
  describe "#feed_moved" do
    let(:user) { create(:user, email: "host@example.com") }
    let(:show) { create(:show, user: user, title: "The Tidepool Hour") }

    it "tells the owner's account address the feed moved and links the verification" do
      mail = described_class.with(show: show, from: "https://old.example.com/feed.xml",
                                  to: "https://new.example.com/feed.xml").feed_moved

      expect(mail.to).to eq([ "host@example.com" ])
      expect(mail.subject).to eq("Your show's feed moved; verify it again")
      text = mail.text_part.body.to_s
      expect(text).to include("The Tidepool Hour", "https://new.example.com/feed.xml",
                              "/shows/#{show.to_param}/verification/new")
      expect(mail.html_part.body.to_s).to include("Verify it again")
      [ text, mail.html_part.body.to_s, mail.subject ].each { |part| expect(part).not_to match(/[\u2013\u2014]/) }
    end

    it "sends nothing to an account with no email" do
      user.update_columns(email: "")
      mail = described_class.with(show: show, from: "a", to: "b").feed_moved
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end
  end
end
