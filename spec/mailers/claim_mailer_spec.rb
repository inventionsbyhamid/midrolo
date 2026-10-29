require "rails_helper"

RSpec.describe ClaimMailer do
  describe "#feed_unreachable" do
    let(:owner) { create(:user, email: "host@example.com") }
    let(:podcast) do
      create(:podcast, title: "The Founder's Ledger", feed_url: "https://feeds.example.com/ledger.xml", claimed_at: 1.day.ago,
                       fetch_failures: 3, last_error: "feed_forbidden")
    end

    before { create(:show, user: owner, podcast: podcast, verified_at: 1.day.ago) }

    it "tells the owner their feed can't be read, that the page stays listed, and what to check" do
      mail = described_class.with(podcast: podcast).feed_unreachable

      expect(mail.to).to eq([ "host@example.com" ])
      expect(mail.subject).to eq("We can't read The Founder's Ledger's feed")
      text = mail.text_part.decoded
      expect(text).to include("3 times in a row", "Feed refused us (401 or 403)", "stays listed", "https://feeds.example.com/ledger.xml",
                              "http://example.com/podcasts/#{podcast.slug}")
      expect(mail.html_part.decoded).to include("Open your page")
      expect([ text, mail.subject ].join).not_to match(/[–—]/)
    end

    it "sends nothing without an owner" do
      podcast.owner_show.update!(verified_at: nil)
      expect(described_class.with(podcast: podcast.reload).feed_unreachable.message).to be_a(ActionMailer::Base::NullMail)
    end
  end

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
