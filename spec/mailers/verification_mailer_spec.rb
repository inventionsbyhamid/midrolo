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

  it "heads the HTML part with the PNG logo at an absolute URL, since many mail clients block SVG" do
    html = Nokogiri::HTML(described_class.with(verification: verification).code.html_part.body.to_s)
    logo = html.at_css("img[alt='Midrolo']")

    expect(logo["src"]).to match(%r{\Ahttp://example\.com/assets/brand/logo-email-\h+\.png\z})
    expect([ logo["width"], logo["height"] ]).to eq(%w[136 28])
    expect(html.css("img[src$='.svg']")).to be_empty
  end

  it "cuts a long feed title to 60 characters in the subject and the body" do
    show.podcast.update!(title: "A" * 50 + " and an attacker's very long sales pitch goes here")
    mail = described_class.with(verification: verification).code
    short = show.title.truncate(60)

    expect(short.length).to eq(60)
    expect(mail.subject).to eq("Your Midrolo code for #{short}")
    expect(mail.text_part.body.to_s).to include(short)
    expect(mail.text_part.body.to_s + mail.html_part.body.to_s).not_to include("sales pitch")
  end

  it "sends from MAIL_FROM when it is set" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("MAIL_FROM", anything).and_return("Kits <kits@example.com>")

    expect(described_class.with(verification: verification).code[:from].value).to eq("Kits <kits@example.com>")
  end

  # Verifications::WatchFeedJob's two results: the line turned up in the feed, or the watch ran out without it.
  describe "the feed watch" do
    let(:owner) { create(:user, email: "host@example.com") }
    let(:show) { create(:show, user: owner, title: "The Founder's Ledger", feed_url: "https://host.example.com/feed.xml") }
    let(:token) { ShowVerification.start_feed_token!(show) }

    def parts(mail) = [ mail.subject, mail.text_part.body.to_s, mail.html_part.body.to_s ]

    it "tells the owner the show is verified, that the line can go, and links the stats page" do
      mail = described_class.with(verification: token).verified
      subject, text, html = parts(mail)

      expect(mail.to).to eq([ "host@example.com" ])
      expect(subject).to eq("The Founder's Ledger is verified on Midrolo")
      [ text, html ].each do |body|
        expect(body).to include("You can remove the midrolo-verify line from your show description now.")
      end
      expect(text).to include("http://example.com/shows/#{show.to_param}/stats")
      link = Nokogiri::HTML(html).at_css("a[data-mail-button]")
      expect(link["href"]).to eq("http://example.com/shows/#{show.to_param}/stats")
      parts(mail).each { |part| expect(part).not_to match(/[\u2013\u2014]/) }
    end

    it "tells the owner the line wasn't found and links the verification page" do
      mail = described_class.with(verification: token).not_found
      subject, text, html = parts(mail)

      expect(mail.to).to eq([ "host@example.com" ])
      expect(subject).to eq("We couldn't verify The Founder's Ledger yet")
      copy = "We couldn't find the line in your feed yet. Make sure you saved the description in your podcast host, " \
             "then press Check my feed again."
      [ text, html ].each { |body| expect(body.squish).to include(copy) }
      expect(text).to include("http://example.com/shows/#{show.to_param}/verification")
      link = Nokogiri::HTML(html).at_css("a[data-mail-button]")
      expect(link["href"]).to eq("http://example.com/shows/#{show.to_param}/verification")
      parts(mail).each { |part| expect(part).not_to match(/[\u2013\u2014]/) }
    end

    it "cuts a long feed title in the subject" do
      show.podcast.update!(title: "A" * 50 + " and an attacker's very long sales pitch goes here")

      expect(described_class.with(verification: token).verified.subject).to eq("#{show.title.truncate(60)} is verified on Midrolo")
    end

    it "sends nothing to an account with no email" do
      owner.update_columns(email: "")

      %i[verified not_found].each do |email|
        expect(described_class.with(verification: token).public_send(email).message).to be_a(ActionMailer::Base::NullMail)
      end
    end
  end
end
