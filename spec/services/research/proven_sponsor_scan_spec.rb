require "rails_helper"

RSpec.describe Research::ProvenSponsorScan do
  let(:taste) { Taste::Providers::Fake.new }
  let(:feed_url) { "https://sponsored.example.com/feed.xml" }
  let(:info) do
    Podcasts::ShowInfo.new(directory_id: "pi-1", title: "The Sponsored Show", author: "Sam Sponsor", description: nil,
                           artwork_url: nil, feed_url: feed_url, categories: [ "Business" ], episode_count: 3,
                           itunes_id: nil, language: "en")
  end
  let(:directory) { instance_double(Podcasts::Directories::Fake) }
  let(:report) { create(:report) }
  let(:toolkit) { Research::Toolkit.new(report, taste: taste, directory: directory) }
  let(:notion_id) { taste.search(query: "Notion", types: [ :brand ], take: 1).first.id }

  before do
    allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ])
    stub_request(:get, feed_url).to_return(status: 200, body: Rails.root.join("spec/fixtures/feeds/sponsored.xml").binread)
    allow(directory).to receive(:search).and_return([])
    allow(directory).to receive(:search).with("The Sponsored Show", limit: 5).and_return([ info ])
  end

  def scan(names = [ "The Sponsored Show" ], limit: 8)
    described_class.call(toolkit, podcast_names: names, limit: limit)
  end

  it "extracts sponsor candidates from the sponsored feed" do
    feed = Podcasts::FeedReader.new.read(feed_url)
    candidates = feed.episodes.flat_map { |e| described_class.extract(e.description) }.uniq
    expect(candidates).to eq([ "Notion", "acme.com" ])
  end

  it "keeps resolved brands with show, episode and date evidence and drops unresolved ones" do
    result = scan

    expect(result.keys).to eq([ notion_id ])
    expect(result[notion_id]).to eq([
      { show: "The Sponsored Show", episode_title: "Episode 3: Notes that organise themselves", published_at: Time.utc(2026, 10, 12, 9) }
    ])
    expect(result[notion_id].first[:published_at]).to be_a(Time)
    expect(toolkit.seen_entity_ids).to include(notion_id)
  end

  it "logs a friendly step per show" do
    scan
    step = report.agent_steps.last
    expect(step).to have_attributes(tool: "proven_sponsor_scan", label: "Checking who sponsors The Sponsored Show…", status: "ok")
    expect(step.output_summary).to eq("Found 1 sponsor on Qloo: Notion")
  end

  it "exposes the resolved brand entities" do
    scanner = described_class.new(toolkit, podcast_names: [ "The Sponsored Show" ], limit: 8)
    scanner.call
    expect(scanner.brands.keys).to eq([ notion_id ])
    expect(scanner.brands[notion_id].name).to eq("Notion")
  end

  it "resolves each candidate once per scan" do
    allow(directory).to receive(:search).with("The Sponsored Show Again", limit: 5).and_return([ info.with(title: "The Sponsored Show Again") ])
    allow(taste).to receive(:search).and_call_original

    result = scan([ "The Sponsored Show", "The Sponsored Show Again" ])
    expect(taste).to have_received(:search).with(hash_including(query: "Notion")).once
    expect(taste).to have_received(:search).with(hash_including(query: "acme")).once
    expect(result[notion_id].map { |e| e[:show] }).to eq([ "The Sponsored Show", "The Sponsored Show Again" ])
  end

  it "lists each brand's evidence newest first across shows" do
    older_url = "https://older.example.com/feed.xml"
    older_xml = Rails.root.join("spec/fixtures/feeds/sponsored.xml").read
                     .sub("<title>The Sponsored Show</title>", "<title>Older Show</title>").gsub("2026", "2025")
    stub_request(:get, older_url).to_return(status: 200, body: older_xml)
    allow(directory).to receive(:search).with("Older Show", limit: 5).and_return([ info.with(title: "Older Show", feed_url: older_url) ])

    result = scan([ "Older Show", "The Sponsored Show" ])
    expect(result[notion_id].map { |e| e[:show] }).to eq([ "The Sponsored Show", "Older Show" ])
  end

  it "honours the limit and skips blanks, duplicates and the user's own show" do
    report.show.update!(title: "My Own Show")
    scan([ "My Own Show", " ", "The Sponsored Show", "the sponsored show", "Another Show" ], limit: 1)
    expect(directory).to have_received(:search).once
  end

  it "skips a show it cannot find in the directory with a warning" do
    expect(scan([ "Unknown Show", "The Sponsored Show" ]).keys).to eq([ notion_id ])
    step = report.agent_steps.order(:position).first
    expect(step.status).to eq("warning")
    expect(step.output_summary).to include("Couldn't find Unknown Show in the podcast directory")
  end

  it "does not trust a directory hit with a different title" do
    allow(directory).to receive(:search).with("Notion Weekly", limit: 5).and_return([ info.with(title: "Completely Different") ])
    expect(scan([ "Notion Weekly" ])).to eq({})
    expect(report.agent_steps.last.status).to eq("warning")
  end

  it "skips a show whose feed cannot be read with a warning" do
    stub_request(:get, feed_url).to_return(status: 500)
    expect(scan).to eq({})
    expect(report.agent_steps.last).to have_attributes(status: "warning")
    expect(report.agent_steps.last.output_summary).to include("Couldn't read The Sponsored Show's feed")
  end

  it "treats a directory outage as a warning and stops scanning" do
    allow(directory).to receive(:search).and_raise(Podcasts::Directory::Unavailable, "down")
    expect(scan([ "The Sponsored Show", "Another Show" ])).to eq({})
    expect(report.agent_steps.count).to eq(1)
    expect(report.agent_steps.last).to have_attributes(status: "warning")
    expect(report.agent_steps.last.output_summary).to include("Podcast directory unavailable")
  end

  it "skips a brand lookup that fails on a Qloo outage, but lets auth errors through" do
    allow(taste).to receive(:search).and_raise(Taste::RateLimited, "429")
    expect(scan).to eq({})
    expect(report.agent_steps.last.status).to eq("warning")

    allow(taste).to receive(:search).and_raise(Taste::AuthError, "401")
    expect { scan }.to raise_error(Taste::AuthError)
  end

  describe ".extract" do
    {
      "This episode is sponsored by Notion." => [ "Notion" ],
      "Thanks to our sponsor Mercury." => [ "Mercury" ],
      "Today's show is brought to you by Rocket Money." => [ "Rocket Money" ],
      "Support for this show comes from Booking.com. Book now." => [ "Booking.com" ],
      "Sponsored by Notion. Try it free" => [ "Notion" ],
      "Go to betterhelp.com/money for 10% off" => [ "betterhelp" ],
      "Use promo code SAVE for hellofresh.com" => [ "hellofresh.com" ],
      "brought to you by AG1, the daily drink" => [ "AG1" ],
      "No sponsors here, thanks for listening." => [],
      "" => []
    }.each do |text, expected|
      it "finds #{expected.inspect} in #{text.inspect}" do
        expect(described_class.extract(text)).to eq(expected)
      end
    end
  end
end
