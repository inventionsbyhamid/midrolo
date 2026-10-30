require "rails_helper"

RSpec.describe Verifications::WatchFeedJob do
  include ActiveJob::TestHelper

  let(:feed_url) { "https://host.example.com/feed.xml" }
  let(:owner) { create(:user, email: "host@example.com") }
  let(:show) { create(:show, user: owner, title: "Token Talk", feed_url: feed_url, owner_email: nil) }
  let(:token) { ShowVerification.start_feed_token!(show) }
  let(:start) { Time.current }

  before do
    allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ])
    freeze_time
    token.update!(watch_until: start + ShowVerification::WATCH_WINDOW)
  end

  def feed_xml(description = "A show about tokens.")
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel><title>Token Talk</title><description><![CDATA[#{description}]]></description>
        <item><title>Ep 1</title><pubDate>Mon, 12 Oct 2026 09:00:00 -0000</pubDate><guid>t-1</guid></item>
      </channel></rss>
    XML
  end

  def feed_without_line = stub_request(:get, feed_url).to_return(status: 200, body: feed_xml)
  def feed_with_line = stub_request(:get, feed_url).to_return(status: 200, body: feed_xml("Hi. #{token.token_line}"))
  def stream = ShowVerification.stream_name(show)

  it "runs on the default queue" do
    expect(described_class.new.queue_name).to eq("default")
  end

  it "verifies on a later check: emails the owner, refreshes an open page and ends the watch" do
    feed_with_line
    travel 3.minutes

    expect { described_class.perform_now(token.id, 3) }
      .to have_enqueued_mail(VerificationMailer, :verified).exactly(:once)
      .and have_broadcasted_to(stream).with { |html| expect(html).to include('action="refresh"') }

    expect(show.reload).to be_verified
    expect(token.reload).to have_attributes(verified_at: be_present, watch_until: nil)
    expect(described_class).not_to have_been_enqueued
  end

  it "stops, with no email and no feed read, when the show was verified another way" do
    request = feed_with_line
    show.verify!(via: "email")

    expect { described_class.perform_now(token.id, 2) }.not_to have_enqueued_mail
    expect(request).not_to have_been_requested
    expect(token.reload.watch_until).to be_nil
    expect(described_class).not_to have_been_enqueued
  end

  it "stops, with no email, once the token has expired" do
    request = feed_with_line
    travel ShowVerification::TOKEN_TTL + 1.minute

    expect { described_class.perform_now(token.id, 5) }.not_to have_enqueued_mail
    expect(request).not_to have_been_requested
    expect(token.reload.watch_until).to be_nil
    expect(described_class).not_to have_been_enqueued
  end

  it "stops, with no email, when the token expires while the feed is read" do
    stub_request(:get, feed_url).to_return do
      travel ShowVerification::TOKEN_TTL + 1.minute
      { status: 200, body: feed_xml("Hi. #{token.token_line}") }
    end

    expect { described_class.perform_now(token.id, 2) }.not_to have_enqueued_mail
    expect(show.reload).not_to be_verified
    expect(token.reload.watch_until).to be_nil
    expect(described_class).not_to have_been_enqueued
  end

  it "stops, with no email, when the feed moves while it is read" do
    podcast = show.podcast
    stub_request(:get, feed_url).to_return do
      travel 1.second
      Podcast.transaction do
        Catalog::FeedMove.record(podcast, from: feed_url, to: "https://moved.example.com/feed.xml", via: "redirect")
      end
      { status: 200, body: feed_xml("Hi. #{token.token_line}") }
    end

    expect { described_class.perform_now(token.id, 2) }.not_to have_enqueued_mail
    expect(show.reload).not_to be_verified
    expect(token.reload.watch_until).to be_nil
    expect(described_class).not_to have_been_enqueued
  end

  it "stops quietly when another account has claimed the podcast meanwhile" do
    feed_with_line
    create(:show, podcast: show.podcast).verify!(via: "email")

    expect { described_class.perform_now(token.id, 2) }.not_to have_enqueued_mail
    expect(show.reload).not_to be_verified
    expect(token.reload).to have_attributes(verified_at: nil, watch_until: nil)
    expect(described_class).not_to have_been_enqueued
  end

  it "stops quietly when the verification is gone" do
    expect { described_class.perform_now(-1, 2) }.not_to raise_error
  end

  it "does nothing for a token that isn't watched" do
    request = feed_with_line
    token.update!(watch_until: nil)

    expect { described_class.perform_now(token.id, 2) }.not_to have_enqueued_mail
    expect(request).not_to have_been_requested
  end

  it "checks at 15 s, 1 min, 3 min and 5 min, then every 5 minutes until the window ends" do
    feed_without_line
    runs = [ 15.seconds, 1.minute, 3.minutes, 5.minutes, 10.minutes, 15.minutes, 20.minutes, 25.minutes, 30.minutes ]

    runs.each_cons(2).with_index(1) do |(now, next_at), check|
      travel_to(start + now)
      clear_enqueued_jobs
      expect { described_class.perform_now(token.id, check) }.not_to have_enqueued_mail

      expect(described_class).to have_been_enqueued.with(token.id, check + 1).at(start + next_at).exactly(:once)
    end
  end

  it "at the window's end, sends exactly one not-found email and ends the watch" do
    feed_without_line
    travel ShowVerification::WATCH_WINDOW

    expect { described_class.perform_now(token.id, 9) }.to have_enqueued_mail(VerificationMailer, :not_found).exactly(:once)
    expect(token.reload.watch_until).to be_nil
    expect(described_class).not_to have_been_enqueued

    expect { described_class.perform_now(token.id, 9) }.not_to have_enqueued_mail # a stray copy finds the watch over
  end

  it "keeps checking an unreadable feed, and sends the not-found email when the window ends" do
    stub_request(:get, feed_url).to_return(status: 500)
    travel 1.minute

    expect { described_class.perform_now(token.id, 2) }.not_to have_enqueued_mail
    expect(described_class).to have_been_enqueued.with(token.id, 3).at(start + 3.minutes)

    travel_to(start + ShowVerification::WATCH_WINDOW)
    expect { described_class.perform_now(token.id, 9) }.to have_enqueued_mail(VerificationMailer, :not_found).exactly(:once)
  end

  it "follows a window a later press extended, with its last check at the new end" do
    feed_without_line
    token.update!(watch_until: start + 32.minutes)
    travel_to(start + 30.minutes)

    expect { described_class.perform_now(token.id, 9) }.not_to have_enqueued_mail
    expect(described_class).to have_been_enqueued.with(token.id, 10).at(start + 32.minutes)
  end
end
