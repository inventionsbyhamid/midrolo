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
end
