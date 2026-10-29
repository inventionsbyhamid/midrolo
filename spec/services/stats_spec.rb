require "rails_helper"

RSpec.describe Stats do
  describe ".show_id_from" do
    it "finds the Spotify show id in a link, a URI or on its own", :aggregate_failures do
      id = "2nel53b14wqMRDx2toN28f"
      expect(described_class.show_id_from("spotify", "https://open.spotify.com/show/#{id}?si=abc123")).to eq(id)
      expect(described_class.show_id_from("spotify", "  https://open.spotify.com/intl-de/show/#{id}  ")).to eq(id)
      expect(described_class.show_id_from("spotify", "spotify:show:#{id}")).to eq(id)
      expect(described_class.show_id_from("spotify", id)).to eq(id)
      expect(described_class.show_id_from("spotify", "https://open.spotify.com/episode/#{id}")).to be_nil
      expect(described_class.show_id_from("spotify", "https://evil.example/#{id}/../x")).to be_nil
      expect(described_class.show_id_from("spotify", "")).to be_nil
    end

    it "finds the Apple podcast id", :aggregate_failures do
      expect(described_class.show_id_from("apple", "https://podcasts.apple.com/us/podcast/the-ledger/id1234567890?i=1")).to eq("1234567890")
      expect(described_class.show_id_from("apple", "id1234567890")).to eq("1234567890")
      expect(described_class.show_id_from("apple", "1234567890")).to eq("1234567890")
      expect(described_class.show_id_from("apple", "https://example.com/id12")).to be_nil
      expect(described_class.show_id_from("apple", "12; rm -rf")).to be_nil
    end
  end

  it "names the platforms and the invite address, from the environment or the default" do
    expect([ described_class.platform_name("apple"), described_class.service_name("spotify") ])
      .to eq([ "Apple Podcasts", "Spotify for Creators" ])
    expect(described_class.invite_email("spotify")).to eq("stats@midrolo.com")
    ENV["MIDROLO_APPLE_EMAIL"] = "apple-stats@example.com"
    expect(described_class.invite_email("apple")).to eq("apple-stats@example.com")
  ensure
    ENV.delete("MIDROLO_APPLE_EMAIL")
  end
end
