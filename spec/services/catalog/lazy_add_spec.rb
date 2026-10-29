require "rails_helper"

# The directory is the demo one (Podcasts::Directories::Fake) unless a spec swaps it.
RSpec.describe Catalog::LazyAdd do
  include ActiveJob::TestHelper

  before { Podcasts::Directory.reset! }

  def directory_with(hits)
    directory = instance_double(Podcasts::Directories::Fake, search: hits)
    allow(Podcasts::Directory).to receive(:current).and_return(directory)
    directory
  end

  def hit(id, title, feed_url, author: "Someone", language: "en")
    Podcasts::ShowInfo.new(directory_id: id, title: title, author: author, description: "From the directory", artwork_url: "https://img.example.com/x.jpg",
                           feed_url: feed_url, categories: [ "News" ], episode_count: 10, itunes_id: nil, language: language)
  end

  it "answers from the catalog alone when it has 5 or more matches" do
    found = Array.new(5) { |i| create(:podcast, title: "Ocean Stories #{i}") }
    directory = directory_with([])

    result = described_class.call("ocean stories")
    expect(result.found).to match_array(found)
    expect(result.added).to eq([])
    expect(directory).not_to have_received(:search)
  end

  # Code review M5: random searches mustn't flood the shared catalog queue or jump ahead of claims.
  it "adds at most 2 directory hits the catalog lacks as pending podcasts, from the directory's ids, feed, title and author only" do
    known = create(:podcast, title: "Known Show", feed_url: "https://feeds.example.com/known.xml")
    hits = [ hit("101", "Known Show", "https://feeds.example.com/known.xml/") ] +
           Array.new(6) { |i| hit((200 + i).to_s, "New Show #{i}", "https://feeds.example.com/new-#{i}.xml") }
    directory_with(hits)

    result = described_class.call("show")

    expect(result.found).to include(known)
    expect(result.added.size).to eq(2)
    added = result.added.first
    expect([ added.status, added.source, added.podcast_index_id, added.title, added.author ]).to eq([ "pending", "search", 200, "New Show 0", "Someone" ])
    expect([ added.description, added.artwork_url, added.categories ]).to eq([ nil, nil, [] ])
    expect(added.next_fetch_at).to be_within(1.minute).of(Catalog::NewPodcast::SAFETY_NET.from_now)
    result.added.each { |podcast| expect(Catalog::IngestPodcastJob).to have_been_enqueued.with(podcast.id).at_priority(10) }
    expect(result.podcasts).to eq(result.found + result.added)
  end

  it "finds a show the catalog has under another spelling of its feed URL instead of adding it twice" do
    known = create(:podcast, feed_url: "https://Feeds.Example.com/known.xml")
    directory_with([ hit("300", "Known", "https://feeds.example.com/known.xml/") ])

    expect { described_class.call("known") }.not_to change(Podcast, :count)
    expect(described_class.call("known").found).to eq([ known ])
  end

  it "skips suppressed and removed shows" do
    Suppression.create!(kind: "podcast", value: Suppression.feed_digest("https://feeds.example.com/gone.xml"))
    create(:podcast, title: "Removed Show", status: "removed", feed_url: "https://feeds.example.com/removed.xml")
    directory_with([ hit("1", "Gone", "https://feeds.example.com/gone.xml"), hit("2", "Removed Show", "https://feeds.example.com/removed.xml") ])

    result = described_class.call("removed show")
    expect(result.podcasts).to eq([])
  end

  it "answers with what the catalog has when the directory is down" do
    found = create(:podcast, title: "Ocean Stories")
    allow(Podcasts::Directory).to receive(:current).and_raise(Podcasts::Directory::Unavailable)
    expect(described_class.call("ocean").found).to eq([ found ])
  end

  it "adds a show from the demo directory end to end" do
    result = described_class.call("founder's ledger")
    expect(result.added.map(&:title)).to eq([ "The Founder's Ledger" ])
    expect(result.added.first.feed_url).to eq("fake://fake-1")
  end

  it "looks a feed URL or an Apple Podcasts link up directly" do
    allow(ShowLookup).to receive(:call).and_call_original
    result = described_class.call("https://podcasts.apple.com/us/podcast/x/id#{Podcasts::Directories::Fake.itunes_id_for('fake-3')}")

    expect(result.added.map(&:title)).to eq([ "Code & Coffee Weekly" ])
    expect(described_class.call("https://podcasts.apple.com/us/podcast/x/id#{Podcasts::Directories::Fake.itunes_id_for('fake-3')}").found)
      .to eq(result.added)
  end

  # Code review M4: a feed nobody lists becomes a catalog page only through a signed-in user.
  describe "a feed URL the directory doesn't list" do
    let(:feed) { "https://feeds.example.com/spam.xml" }

    before do
      allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ])
      stub_request(:get, feed).to_return(status: 200, body: Rails.root.join("spec/fixtures/feeds/catalog_namespace.xml").binread)
    end

    it "is never read for a visitor" do
      expect(described_class.call(feed).podcasts).to eq([])
      expect(a_request(:get, feed)).not_to have_been_made
      expect(Podcast.count).to eq(0)
    end

    it "is read and added for a signed-in user, at normal priority" do
      result = described_class.call(feed, signed_in: true)
      expect(result.added.map(&:feed_url)).to eq([ feed ])
      expect(Catalog::IngestPodcastJob).to have_been_enqueued.with(result.added.first.id).at_priority(10)
    end

    it "finds a podcast the catalog already has under that feed for anyone" do
      known = create(:podcast, feed_url: feed)
      expect(described_class.call("#{feed}/").found).to eq([ known ])
      expect(a_request(:get, feed)).not_to have_been_made
    end
  end

  it "is empty for an empty query" do
    expect(described_class.call("   ").podcasts).to eq([])
  end
end
