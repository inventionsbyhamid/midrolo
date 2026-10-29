require "rails_helper"

RSpec.describe Claims::HostHelp do
  it "knows Spotify for Creators by its anchor.fm feed before ingest names the host" do
    podcast = build(:podcast, feed_url: "https://anchor.fm/s/abc123/podcast/rss", hosting_provider: nil)
    help = described_class.for(podcast)

    expect(help).to be_known
    expect(help.name).to eq("Spotify for Creators")
    expect(help.email_steps.join(" ")).to include("Settings, then Availability", "Add email to RSS feed")
    expect(help.description_steps.join(" ")).to include("description")
  end

  it "uses the host ingest detected" do
    podcast = build(:podcast, feed_url: "https://feeds.example.com/x.xml", hosting_provider: "buzzsprout")
    expect(described_class.for(podcast).name).to eq("Buzzsprout")
  end

  it "gives the general steps for any other host, or a broken URL" do
    [ "https://feeds.transistor.fm/ledger", "not a url" ].each do |url|
      help = described_class.for(build(:podcast, feed_url: url, hosting_provider: "transistor"))
      expect(help).not_to be_known
      expect(help.wait).to include("15 minutes to a few hours")
    end
  end
end
