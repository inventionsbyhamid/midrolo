require "rails_helper"

RSpec.describe Claims::DemoSetup do
  let!(:admin) { create(:user, admin: true, email: "admin@example.com") }

  it "makes the demo show: owned and verified by the first admin, a published listing, demo numbers, never indexed" do
    podcast = described_class.call(today: Date.new(2026, 10, 30))

    expect(podcast).to have_attributes(title: "Midrolo Demo Show", demo?: true, indexable: false, status: "active",
                                       source: "admin", feed_url: "http://example.com/demo/feed.xml", episode_count: 6,
                                       owner_email: nil, next_fetch_at: nil)
    expect(podcast.episodes.count).to eq(6)
    expect(podcast.owner_show.user).to eq(admin)
    expect(podcast).to be_claimed

    kit = podcast.listing
    expect(kit).to be_published
    expect(kit).to have_attributes(open_to_sponsors: true, open_months: %w[2026-10 2026-11 2026-12],
                                   exclusions: %w[Gambling Crypto])
    reading = podcast.best_downloads_reading
    expect(reading).to have_attributes(value: 1800, trust: "provided", source: "provided", evidence: { "demo" => true })
    expect(podcast.reload).to have_attributes(open_to_sponsors: true, downloads_per_episode: 1800, downloads_trust: "provided")
    expect(podcast.min_price_cents).to be_positive
  end

  it "is safe to run again: one podcast, its episodes, one owner show, one reading" do
    2.times { described_class.call }

    podcast = Podcast.demo.sole
    expect(podcast.episodes.count).to eq(6)
    expect(podcast.shows.count).to eq(1)
    expect(podcast.stat_readings.count).to eq(1)
    expect(MediaKit.count).to eq(1)
  end

  it "takes the owner from DEMO_OWNER_EMAIL, moving the show from the earlier owner" do
    described_class.call
    other = create(:user, email: "Judge.Host@example.com")

    podcast = described_class.call(owner_email: "judge.host@example.com")

    expect(podcast.owner_show.user).to eq(other)
    expect(podcast.shows.find_by(user: admin)).not_to be_verified
  end

  it "says what's missing when there's no owner account" do
    admin.update!(admin: false)
    expect { described_class.call }.to raise_error(described_class::NoOwner, /No admin account/)
    expect { described_class.call(owner_email: "nobody@example.com") }.to raise_error(described_class::NoOwner, /nobody@example.com/)
  end
end
