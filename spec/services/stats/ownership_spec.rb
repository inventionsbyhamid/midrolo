require "rails_helper"

RSpec.describe Stats::Ownership do
  let(:owner) { create(:user) }
  let(:podcast) { create(:podcast, :claimed, title: "The Founder's Ledger", feed_url: "https://feeds.example.com/ledger") }
  let(:connection) { build(:stat_connection, podcast: podcast, user: owner, provider: "spotify") }

  before { create(:show, user: owner, podcast: podcast, verified_at: 1.day.ago) }

  it "passes the owner's connection, and nobody else's" do
    expect(described_class.owner_problem(connection)).to be_nil
    connection.user = create(:user)
    expect(described_class.owner_problem(connection)).to include("Another account owns this show")
    connection.user = nil
    expect(described_class.owner_problem(connection)).to include("Another account owns this show")
    podcast.update!(claimed_at: nil)
    expect(described_class.owner_problem(connection)).to include("Claim this show first")
  end

  it "matches the platform's show by feed or by name", :aggregate_failures do
    expect(described_class.show_problem(connection, "rss_url" => "http://feeds.example.com/ledger/")).to be_nil
    expect(described_class.show_problem(connection, "name" => "Founder's Ledger")).to be_nil
    expect(described_class.show_problem(connection, "name" => "Ledger"))
      .to eq("The Spotify show at that link isn't The Founder's Ledger. Check the link you pasted.")
    expect(described_class.show_problem(connection, "name" => "", "rss_url" => "https://feeds.example.com/other"))
      .to include("We couldn't confirm")
    expect(described_class.show_problem(connection, {})).to include("We couldn't confirm")
  end
end
