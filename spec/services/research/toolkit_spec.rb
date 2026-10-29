require "rails_helper"

RSpec.describe Research::Toolkit do
  let(:show) { create(:show, feed_url: "fake://fake-1") }
  let(:report) { create(:report, show: show) }
  let(:toolkit) { described_class.new(report) }

  it "uses the current providers by default" do
    expect(toolkit.taste).to equal(Taste::Provider.current)
    expect(toolkit.directory).to equal(Podcasts::Directory.current)
    expect(toolkit.log).to be_a(Research::StepLogger)
    expect(toolkit.show).to eq(show)
  end

  it "reads the show's feed once, 15 episodes deep" do
    reader = instance_double(Podcasts::FeedReader)
    feed = Podcasts::Feed.unreadable
    allow(reader).to receive(:read).with("fake://fake-1", max_episodes: 15).and_return(feed)
    kit = described_class.new(report, feed_reader: reader)

    2.times { expect(kit.feed).to equal(feed) }
    expect(reader).to have_received(:read).once
  end

  # A podcast made from a show that had only a directory id keeps a placeholder feed URL no one can fetch.
  it "returns an unreadable feed when the podcast has no real feed url" do
    show.podcast.update_columns(feed_url: "directory:577105")
    expect(toolkit.feed.episodes).to eq([])
    expect(toolkit.feed.warnings).not_to be_empty
  end

  it "remembers entity ids, and accepts plain ids" do
    entity = Taste::Providers::Fake.new.search(query: "Notion", types: [ :brand ]).first
    toolkit.remember([ entity ])
    toolkit.remember("fake:brand:ramp")

    expect(toolkit.seen_entity_ids).to eq(Set[entity.id, "fake:brand:ramp"])
  end

  it "tracks the run's uncached taste calls against its budget" do
    kit = described_class.new(report, taste: Taste::Providers::Fake.new, max_taste_calls: 1)
    expect(kit.taste_calls).to eq(0)
    kit.log.step("x", "Looking…") { kit.taste.search(query: "Notion", types: [ :brand ]) }
    expect(kit.taste_calls).to eq(1)
    expect(kit.over_taste_budget?).to be(true)
  end

  it "starts with no audience tags" do
    expect(toolkit.audience_tags).to eq([])
  end
end
