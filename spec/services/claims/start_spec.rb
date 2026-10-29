require "rails_helper"

RSpec.describe Claims::Start do
  let(:user) { create(:user, email: "jane@example.com") }
  let(:podcast) { create(:podcast, :active, feed_url: "https://feeds.example.com/ledger.xml") }
  let(:reader) { instance_double(Podcasts::FeedReader) }

  def feed(owner_email: nil, warnings: [])
    Podcasts::Feed.new(title: "Ledger", description: "About", owner_email: owner_email, owner_name: nil, episodes: [],
                       cadence_days: nil, warnings: warnings)
  end

  def start = described_class.call(user: user, podcast: podcast, reader: reader)

  it "reads the feed fresh, with no episodes" do
    allow(reader).to receive(:read).and_return(feed)
    start
    expect(reader).to have_received(:read).with(podcast.feed_url, max_episodes: 0, fresh: true)
  end

  it "claims at once for the feed's owner address and a Google sign in" do
    allow(reader).to receive(:read).and_return(feed(owner_email: " JANE@example.com "))

    result = start
    expect(result).to be_verified
    expect(result.show).to be_verified
    expect(podcast.reload.claimed_at).to be_present
  end

  it "never claims at once for a sign in that didn't check the address" do
    user.update!(provider: "developer")
    allow(Rails.env).to receive(:local?).and_return(false)
    allow(reader).to receive(:read).and_return(feed(owner_email: "jane@example.com"))

    expect(start.outcome).to eq(:verify)
  end

  it "leaves the stored owner email alone when the feed can't be read" do
    podcast.update!(owner_email: "host@example.com")
    allow(reader).to receive(:read).and_return(feed(warnings: [ "feed_timeout" ]))

    expect(start.outcome).to eq(:verify)
    expect(podcast.reload.owner_email).to eq("host@example.com")
  end

  it "clears an owner email the feed no longer lists" do
    podcast.update!(owner_email: "host@example.com")
    allow(reader).to receive(:read).and_return(feed)

    start
    expect(podcast.reload.owner_email).to be_nil
  end

  it "raises AlreadyClaimed for another account's show, before making a workspace" do
    create(:show, podcast: podcast).verify!(via: "admin")
    allow(reader).to receive(:read)

    expect { start }.to raise_error(Show::AlreadyClaimed)
    expect(user.shows).to be_empty
    expect(reader).not_to have_received(:read)
  end

  it "answers :owner for the user's own claimed show without reading the feed" do
    show = create(:show, user: user, podcast: podcast)
    show.verify!(via: "admin")
    allow(reader).to receive(:read)

    expect(start).to have_attributes(show: show, outcome: :owner)
    expect(reader).not_to have_received(:read)
  end
end
