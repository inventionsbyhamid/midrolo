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
  let(:notion_id) { brand_id("Notion") }

  before do
    allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ])
    stub_request(:get, feed_url).to_return(status: 200, body: Rails.root.join("spec/fixtures/feeds/sponsored.xml").binread)
    allow(directory).to receive(:search).and_return([])
    allow(directory).to receive(:search).with("The Sponsored Show", limit: 5).and_return([ info ])
  end

  def brand_id(name) = taste.search(query: name, types: [ :brand ], take: 1).first.id

  def scan(names = [ "The Sponsored Show" ], limit: 8)
    described_class.call(toolkit, podcast_names: names, limit: limit)
  end

  # Synthetic RSS: one item per description (HTML allowed), newest first, a week apart.
  def feed_xml(descriptions, title: "The Sponsored Show", owner: "Sam Sponsor", email: "host@sponsored.example.com")
    items = descriptions.each_with_index.map do |html, i|
      date = (Time.utc(2026, 10, 12, 9) - i.weeks).rfc2822
      "<item><title>Episode #{descriptions.size - i}</title><description><![CDATA[#{html}]]></description>" \
        "<pubDate>#{date}</pubDate><guid>ep-#{descriptions.size - i}</guid></item>"
    end
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>#{title}</title>
        <itunes:owner><itunes:name>#{owner}</itunes:name><itunes:email>#{email}</itunes:email></itunes:owner>
        #{items.join("\n")}
      </channel></rss>
    XML
  end

  def serve(descriptions, **opts)
    stub_request(:get, feed_url).to_return(status: 200, body: feed_xml(descriptions, **opts))
  end

  # A second similar show, "Other Show", with its own feed.
  def serve_other(descriptions, **opts)
    other_url = "https://other.example.com/feed.xml"
    stub_request(:get, other_url).to_return(status: 200, body: feed_xml(descriptions, title: "Other Show", **opts))
    allow(directory).to receive(:search).with("Other Show", limit: 5).and_return([ info.with(title: "Other Show", feed_url: other_url) ])
  end

  # Fake search, plus extra brands the Fake catalog doesn't have.
  def with_extra_brands(*names)
    extra = names.to_h do |name|
      [ Research::Names.normalize(name), Taste::Entity.new(id: "fake:brand:#{name.parameterize}", name: name, type: :brand, popularity: 0.3,
                                                         affinity: nil, image_url: nil, description: nil, website: nil, tags: [], properties: {}) ]
    end
    allow(taste).to receive(:search).and_wrap_original do |original, **kw|
      hit = extra[Research::Names.normalize(kw[:query])]
      hit ? [ hit ] : original.call(**kw)
    end
  end

  it "extracts sponsor candidates from the sponsored feed" do
    feed = Podcasts::FeedReader.new.read(feed_url)
    candidates = feed.episodes.flat_map { |e| described_class.extract(e.description) }.uniq
    expect(candidates).to eq([ "Notion", "acme.com" ])
  end

  it "keeps resolved brands with show, episode and date evidence and drops unresolved ones" do
    result = scan

    expect(result.keys).to eq([ notion_id ])
    expect(result[notion_id]).to eq(
      items: [ { show: "The Sponsored Show", episode_title: "Episode 3: Notes that organise themselves", published_at: Time.utc(2026, 10, 12, 9) } ],
      count: 1
    )
    expect(result[notion_id][:items].first[:published_at]).to be_a(Time)
    expect(toolkit.seen_entity_ids).to include(notion_id)
  end

  it "logs a friendly step per show, then one step confirming the names on Qloo" do
    scan
    show_step, confirm_step = report.agent_steps.order(:position).last(2)

    expect(show_step).to have_attributes(tool: "proven_sponsor_scan", label: "Checking who sponsors The Sponsored Show…", status: "ok")
    expect(show_step.output_summary).to eq("Found 2 sponsor reads: Notion, acme.com")
    expect(confirm_step).to have_attributes(tool: "proven_sponsor_scan", label: "Confirming sponsors on Qloo…", status: "ok")
    expect(confirm_step.output_summary).to eq("Matched 1 of 2 names on Qloo: Notion")
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
    expect(result[notion_id][:items].map { |e| e[:show] }).to eq([ "The Sponsored Show", "The Sponsored Show Again" ])
  end

  it "lists each brand's evidence newest first across shows" do
    older_url = "https://older.example.com/feed.xml"
    older_xml = Rails.root.join("spec/fixtures/feeds/sponsored.xml").read
                     .sub("<title>The Sponsored Show</title>", "<title>Older Show</title>").gsub("2026", "2025")
    stub_request(:get, older_url).to_return(status: 200, body: older_xml)
    allow(directory).to receive(:search).with("Older Show", limit: 5).and_return([ info.with(title: "Older Show", feed_url: older_url) ])

    result = scan([ "Older Show", "The Sponsored Show" ])
    expect(result[notion_id][:items].map { |e| e[:show] }).to eq([ "The Sponsored Show", "Older Show" ])
  end

  it "keeps the 3 latest evidence items per brand plus the total count" do
    serve(Array.new(5) { "This episode is sponsored by Notion." })
    evidence = scan[notion_id]

    expect(evidence[:count]).to eq(5)
    expect(evidence[:items].map { |e| e[:episode_title] }).to eq([ "Episode 5", "Episode 4", "Episode 3" ])
  end

  it "resolves at most 8 names per scan, the most frequent first (R93)" do
    once = %w[Alder Birch Cedar Dogwood Elmwood Firtree Ginkgo Hazel Ironbark Juniper Kapok Larch Maplewood Nutmeg Olivewood Pinewood]
    serve(once.map { |n| "This episode is sponsored by #{n}." } + Array.new(3) { "This episode is sponsored by Notion." })
    allow(taste).to receive(:search).and_call_original

    result = scan
    expect(taste).to have_received(:search).exactly(8).times
    expect(taste).to have_received(:search).with(hash_including(query: "Notion"))
    expect(taste).not_to have_received(:search).with(hash_including(query: "Hazel"))
    expect(result.keys).to eq([ notion_id ])
    expect(report.agent_steps.order(:position).last.output_summary).to include("8 most frequent of 17 names")
  end

  it "takes 3 hits from one lookup and keeps the one with the same name, since Qloo search is fuzzy (R107)" do
    serve([ "This episode is sponsored by Notion." ])
    notion = taste.search(query: "Notion", types: [ :brand ], take: 1).first
    decoy = notion.with(id: "fake:brand:notion-calendar", name: "Notion Calendar")
    allow(taste).to receive(:search).and_return([ decoy, notion ])

    expect(scan.keys).to eq([ notion.id ])
    expect(taste).to have_received(:search).with(query: "Notion", types: [ :brand ], take: 3).once
  end

  it "stops resolving once the run's research budget is spent" do
    kit = Research::Toolkit.new(report, taste: taste, directory: directory, max_taste_calls: 1)
    serve([ "This episode is sponsored by Ramp.", "This episode is sponsored by Notion." ])

    expect(described_class.call(kit, podcast_names: [ "The Sponsored Show" ], limit: 8).keys).to eq([ brand_id("Ramp") ])
    expect(report.agent_steps.order(:position).last).to have_attributes(status: "warning")
    expect(report.agent_steps.order(:position).last.output_summary).to include("Skipped to stay within research budget")
  end

  describe "platform and self-promotion links (R32)" do
    before { report.show.update!(title: "My Own Show") }

    it "never treats them as sponsors, but keeps real sponsors" do
      serve([
        "Support us: go to patreon.com/ourshow today.",
        "This episode is brought to you by Patreon supporters like you.",
        "This episode is brought to you by the letter A.",
        "Brought to you by A. Thanks to our sponsor X.",
        "Thanks to our sponsor Spotify.",
        "Use code SHOW at gumroad.com for the workbook.",
        "Go to ko-fi.com/ourshow to tip.",
        "This episode is sponsored by Apple Podcasts subscribers.",
        "Support for this show comes from Buy Me a Coffee.",
        "This episode is brought to you by The Sponsored Show.",
        "Today's show is brought to you by Sam Sponsor.",
        "Go to sponsored.com/merch for shirts.",
        "Brought to you by My Own Show.",
        "This episode is sponsored by Squarespace."
      ])
      squarespace_id = brand_id("Squarespace")
      allow(taste).to receive(:search).and_call_original

      result = scan
      expect(result.keys).to eq([ squarespace_id ])
      expect(taste).to have_received(:search).with(hash_including(types: [ :brand ])).once
    end

    it "excludes each similar show's own title" do
      serve([ "This episode is brought to you by Other Pod.", "This episode is sponsored by Notion." ])
      allow(directory).to receive(:search).with("Other Pod", limit: 5).and_return([])
      allow(taste).to receive(:search).and_call_original

      scan([ "The Sponsored Show", "Other Pod" ])
      expect(taste).not_to have_received(:search).with(hash_including(query: "Other Pod"))
    end

    it "never drops a webmail provider because the host uses it for email" do
      with_extra_brands("Gmail")
      serve([ "This episode is sponsored by Gmail." ], email: "host@gmail.com")

      expect(scan.keys).to eq([ "fake:brand:gmail" ])
    end

    it "keeps Proton Mail sponsor reads when another show's host emails from protonmail.com" do
      with_extra_brands("Proton Mail")
      serve([ "This episode is sponsored by Notion." ], email: "hey@protonmail.com")
      serve_other([ "This episode is sponsored by Proton Mail." ], owner: "Olive Other", email: "olive@other.example.com")

      result = scan([ "The Sponsored Show", "Other Show" ])
      expect(result["fake:brand:proton-mail"][:items].map { |e| e[:show] }).to eq([ "Other Show" ])
    end

    it "applies a feed owner's exclusion only to that owner's own feed" do
      with_extra_brands("Morning Brew")
      serve([ "This episode is brought to you by Morning Brew." ], owner: "Morning Brew", email: "pods@morningbrew.com")
      serve_other([ "This episode is sponsored by Morning Brew.", "Go to morningbrew.com/daily to subscribe." ],
                  owner: "Olive Other", email: "olive@other.example.com")

      evidence = scan([ "The Sponsored Show", "Other Show" ])["fake:brand:morning-brew"]
      expect(evidence[:items].map { |e| e[:show] }).to eq([ "Other Show", "Other Show" ])
      expect(evidence[:count]).to eq(2)
    end

    it "loads the webmail providers from config/proven_scan.yml" do
      expect(Rails.application.config_for(:proven_scan)[:webmail_domains]).to include("gmail", "protonmail", "hey", "zoho", "me")
    end

    it "loads the denylist from config/proven_scan.yml" do
      expect(Rails.application.config_for(:proven_scan)[:denylist]).to include("patreon", "buy me a coffee", "ko-fi")
      expect(described_class.denylisted?("Patreon")).to be(true)
      expect(described_class.denylisted?("Buy Me a Coffee")).to be(true)
      expect(described_class.denylisted?("kofi.com")).to be(true)
      expect(described_class.denylisted?("X")).to be(true)
      expect(described_class.denylisted?("Squarespace")).to be(false)
      expect(described_class.denylisted?("Notion")).to be(false)
    end
  end

  describe "real-world show notes (R33)" do
    it "reads up to 4,000 characters of each description, so late sponsor lines are found" do
      serve([ "<p>#{'Long show notes. ' * 50}</p><p>This episode is sponsored by Notion.</p>" ])
      allow(toolkit.feed_reader).to receive(:read).and_call_original

      expect(scan.keys).to eq([ notion_id ])
      expect(toolkit.feed_reader).to have_received(:read).with(feed_url, max_episodes: 20, description_limit: 4000)
    end

    it "does not run paragraphs together" do
      serve([ "<p>Sponsored by Notion</p><p>Visit Today</p>" ])
      expect(scan.keys).to eq([ notion_id ])
    end

    it "reads names spaced with &nbsp;" do
      serve([ "<p>This episode is sponsored by&nbsp;Rocket&nbsp;Money.</p><p>&nbsp;</p>" ])
      expect(scan.keys).to eq([ brand_id("Rocket Money") ])
    end

    it "finds a promo-code domain spaced with &nbsp;" do
      serve([ "<p>Use code PODS at&nbsp;acme.com today</p>" ])
      feed = Podcasts::FeedReader.new.read(feed_url, description_limit: 4000)
      expect(described_class.extract(feed.episodes.first.description)).to eq([ "acme.com" ])
    end

    it "resolves a possessive capture to the brand" do
      serve([ "This episode is brought to you by Notion’s new AI." ])
      expect(scan.keys).to eq([ notion_id ])
    end
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
      "Sponsored by Notion\nVisit Today" => [ "Notion" ],
      "This episode is sponsored by\u00A0Rocket\u00A0Money." => [ "Rocket Money" ],
      "Go to betterhelp.com/money for 10% off" => [ "betterhelp" ],
      "Use promo code SAVE for hellofresh.com" => [ "hellofresh.com" ],
      "brought to you by AG1, the daily drink" => [ "AG1" ],
      "This episode is sponsored by Café Nero." => [ "Café Nero" ],
      "Today's show is brought to you by Trader Joe’s." => [ "Trader Joe’s" ],
      "This episode is brought to you by the letter A." => [],
      "No sponsors here, thanks for listening." => [],
      "" => []
    }.each do |text, expected|
      it "finds #{expected.inspect} in #{text.inspect}" do
        expect(described_class.extract(text)).to eq(expected)
      end
    end
  end
end
