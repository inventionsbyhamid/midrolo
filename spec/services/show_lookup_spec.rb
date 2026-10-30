require "rails_helper"

RSpec.describe ShowLookup do
  let(:itunes_id) { Podcasts::Directories::Fake.new.find("fake-4").itunes_id }

  describe "Apple Podcasts links" do
    let(:directory) { instance_double(Podcasts::Directories::Fake, find_by_itunes_id: nil, find_by_feed_url: nil) }

    before { allow(Podcasts::Directory).to receive(:current).and_return(directory) }

    {
      "https://podcasts.apple.com/us/podcast/my-id2-show/id12345" => "12345",
      "https://podcasts.apple.com/us/podcast/the-show/id12345?i=1000" => "12345",
      "https://podcasts.apple.com/us/podcast/the-show/ID12345" => "12345",
      "https://podcasts.apple.com/us/podcast/the-show/id12345/" => "12345",
      "podcasts.apple.com/us/podcast/id-9-things/id777#top" => "777"
    }.each do |url, expected|
      it "extracts #{expected} from #{url}" do
        described_class.call(feed_url: url)
        expect(directory).to have_received(:find_by_itunes_id).with(expected)
      end
    end

    it "does not treat a link without a final id segment as Apple" do
      allow(Podcasts::FeedReader).to receive(:new).and_return(instance_double(Podcasts::FeedReader, read: Podcasts::Feed.unreadable))
      described_class.call(feed_url: "https://podcasts.apple.com/us/podcast/my-id2-show")
      expect(directory).not_to have_received(:find_by_itunes_id)
    end
  end

  describe "a feed URL the directory refuses (Podcast Index answers 400 for some feeds)" do
    let(:url) { "https://anchor.fm/s/12d45dac/podcast/rss" }
    let(:directory) { instance_double(Podcasts::Directories::Fake) }
    let(:feed) do
      Podcasts::Feed.new(title: "AiGM by AiHunt", description: "About AI", owner_email: nil, owner_name: "AiHunt",
                         episodes: [], cadence_days: nil, warnings: [])
    end

    before do
      allow(Podcasts::Directory).to receive(:current).and_return(directory)
      allow(directory).to receive(:find_by_feed_url).and_raise(Podcasts::Directory::Unavailable, "HTTP 400")
      allow(Podcasts::FeedReader).to receive(:new).and_return(instance_double(Podcasts::FeedReader, read: feed))
    end

    it "reads the feed itself instead of failing" do
      result = described_class.call(feed_url: url)
      expect(result).to be_ok
      expect(result.attributes).to include(feed_url: url, title: "AiGM by AiHunt", author: "AiHunt")
    end

    it "still says the directory is down when it may not read feeds" do
      expect { described_class.call(feed_url: url, read_feed: false) }.to raise_error(Podcasts::Directory::Unavailable)
    end
  end

  it "finds the show through the fake directory" do
    result = described_class.call(feed_url: "https://podcasts.apple.com/us/podcast/x/id#{itunes_id}?i=1")
    expect(result.attributes[:directory_id]).to eq("fake-4")
  end
end
