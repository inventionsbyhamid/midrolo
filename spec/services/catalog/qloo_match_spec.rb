require "rails_helper"

# Entities are hand-made Taste::Entity values (never real Qloo data); the directory is the demo one unless swapped.
RSpec.describe Catalog::QlooMatch do
  include ActiveJob::TestHelper

  before { Podcasts::Directory.reset! }

  def entity(id, name, popularity: 0.4, properties: {})
    Taste::Entity.new(id: id, name: name, type: :podcast, popularity: popularity, affinity: nil, image_url: nil,
                      description: nil, website: nil, tags: [], properties: properties)
  end

  def hit(id, title, author, language: "en")
    Podcasts::ShowInfo.new(directory_id: id, title: title, author: author, description: nil, artwork_url: nil,
                           feed_url: "https://feeds.example.com/#{id}.xml", categories: [], episode_count: 5, itunes_id: nil,
                           language: language)
  end

  def directory_with(hits)
    directory = instance_double(Podcasts::Directories::Fake, search: hits)
    allow(Podcasts::Directory).to receive(:current).and_return(directory)
    directory
  end

  it "finds the podcast already linked to the entity, by entity or by id" do
    podcast = create(:podcast, qloo_entity_id: "Q-1")
    expect(described_class.call(entity("Q-1", "Anything"))).to eq(podcast)
    expect(described_class.call("Q-1")).to eq(podcast)
    expect(described_class.call("Q-2")).to be_nil
    expect(described_class.call(nil)).to be_nil
  end

  it "links a catalog podcast with the same title key and a close author, taking the entity's popularity" do
    podcast = create(:podcast, title: "The Darknet Diaries", author: "Jack Rhysider")
    directory = directory_with([])

    match = described_class.call(entity("Q-9", "Darknet Diaries", popularity: 0.71, properties: { "channel" => "Jack Rhysider" }))
    expect(match).to eq(podcast)
    expect([ podcast.reload.qloo_entity_id, podcast.qloo_popularity ]).to eq([ "Q-9", 0.71 ])
    expect(directory).not_to have_received(:search)
  end

  it "won't guess between two catalog podcasts of one title when the entity names no author" do
    2.times { |i| create(:podcast, title: "Daily Brief", feed_url: "https://feeds.example.com/brief-#{i}.xml") }
    directory_with([])
    expect(described_class.call(entity("Q-3", "Daily Brief"))).to be_nil
  end

  # Code review M4: a same-titled clone mustn't take a Qloo identity by being the only unlinked one of its title.
  it "links a lone title only when it is the catalog's only podcast of that title, else needs the author" do
    create(:podcast, title: "Darknet Diaries", author: "Jack Rhysider", qloo_entity_id: "Q-real")
    clone = create(:podcast, title: "Darknet Diaries", author: "Clone Maker", feed_url: "https://feeds.example.com/clone.xml")
    directory_with([])

    expect(described_class.call(entity("Q-new", "Darknet Diaries"), directory: false)).to be_nil
    expect(clone.reload.qloo_entity_id).to be_nil

    expect(described_class.call(entity("Q-new", "Darknet Diaries", properties: { "author" => "Clone Maker" }), directory: false))
      .to eq(clone)
    expect(clone.reload.qloo_entity_id).to eq("Q-new")
  end

  # Final review N5: a feed added by its URL alone (no directory id) never takes a Qloo identity by its title alone.
  it "links a lone same-titled podcast by its title alone only when a directory lists it, else needs the author" do
    clone = create(:podcast, title: "Huge Show", author: "Clone Maker", feed_url: "https://feeds.example.com/huge-clone.xml")
    directory_with([])

    expect(described_class.call(entity("Q-huge", "Huge Show"), directory: false)).to be_nil
    expect(clone.reload.qloo_entity_id).to be_nil

    clone.update!(apple_id: 4242)
    expect(described_class.call(entity("Q-huge", "Huge Show"), directory: false)).to eq(clone)
  end

  it "prefers a directory-listed podcast among same-titled ones whose authors both match" do
    create(:podcast, title: "Twin Show", author: "Jo Host", feed_url: "https://feeds.example.com/twin-copy.xml")
    listed = create(:podcast, title: "Twin Show", author: "Jo Host", podcast_index_id: 77, feed_url: "https://feeds.example.com/twin.xml")
    directory_with([])

    expect(described_class.call(entity("Q-twin", "Twin Show", properties: { "author" => "Jo Host" }), directory: false)).to eq(listed)
  end

  it "adds the directory hit with an equal title and a close author, queued at the caller's priority" do
    directory = directory_with([ hit("1", "Night Owls", "Someone Else"), hit("2", "Night Owls!", "Rita Moreno"),
                                 hit("3", "Night Owls Extra", "Rita Moreno") ])

    match = described_class.call(entity("Q-4", "Night Owls", properties: { "author" => "Rita Moreno" }), source: "qloo_seed", priority: :low)

    expect(match.podcast_index_id).to eq(2)
    expect([ match.qloo_entity_id, match.source, match.status ]).to eq([ "Q-4", "qloo_seed", "pending" ])
    expect(Catalog::IngestPodcastJob).to have_been_enqueued.with(match.id).at_priority(20)
    expect(directory).to have_received(:search).with("Night Owls", limit: 10)
  end

  it "takes a lone same-title hit even when the entity's maker reads differently, but not one of several" do
    directory_with([ hit("11", "Glass Cannon", "Jo Park") ])
    expect(described_class.call(entity("Q-11", "Glass Cannon", properties: { "channel" => "Big Network" }))&.podcast_index_id).to eq(11)

    directory_with([ hit("12", "The Daily", "Ann"), hit("13", "The Daily", "Ben") ])
    expect(described_class.call(entity("Q-12", "The Daily", properties: { "channel" => "Carla" }))).to be_nil
  end

  it "takes a lone same-title hit when the entity names no author, and only English ones when asked" do
    directory_with([ hit("5", "Le Podcast", "Anne", language: "fr") ])
    expect(described_class.call(entity("Q-5", "Le Podcast"), english_only: true)).to be_nil
    expect(described_class.call(entity("Q-5", "Le Podcast"))&.podcast_index_id).to eq(5)
  end

  it "returns the show the directory hit already is in the catalog, keeping its link to another entity" do
    podcast = create(:podcast, title: "Taken Show", qloo_entity_id: "Q-other", feed_url: "https://feeds.example.com/6.xml")
    directory_with([ hit("6", "Taken Show", "Host Person") ])

    expect(described_class.call(entity("Q-7", "Taken Show"))).to eq(podcast)
    expect(podcast.reload.qloo_entity_id).to eq("Q-other")
  end

  it "stays inside the catalog with directory: false, and is nil when the directory is down" do
    directory = directory_with([ hit("8", "Quiet Hours", "A") ])
    expect(described_class.call(entity("Q-8", "Quiet Hours"), directory: false)).to be_nil
    expect(directory).not_to have_received(:search)

    allow(directory).to receive(:search).and_raise(Podcasts::Directory::Unavailable)
    expect(described_class.call(entity("Q-8", "Quiet Hours"))).to be_nil
  end

  it "calls before_directory_call before each directory search" do
    directory_with([])
    calls = 0
    described_class.call(entity("Q-10", "Unknown Show"), before_directory_call: -> { calls += 1 })
    expect(calls).to eq(1)
  end

  it "matches the demo taste catalog to the demo directory" do
    taste = Taste::Provider.current.search(query: "Cold Case Cafe", types: [ :podcast ]).first
    match = described_class.call(taste)
    expect([ match.title, match.qloo_entity_id, match.feed_url ]).to eq([ "Cold Case Cafe", taste.id, "fake://fake-8" ])
  end
end
