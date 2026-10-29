# Feeds for the claim specs (lane L4): stub_claim_feed(url, owner_email:, description:, txt:) answers url with a small
# RSS feed, through a public address so Podcasts::SafeUrl lets the read through.
module ClaimFeeds
  def claim_feed_xml(owner_email: nil, description: "About the show.", txt: nil)
    owner = owner_email ? "<itunes:owner><itunes:name>Owner</itunes:name><itunes:email>#{owner_email}</itunes:email></itunes:owner>" : ""
    tag = txt ? %(<podcast:txt purpose="verify">#{txt}</podcast:txt>) : ""
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0">
        <channel><title>The Founder's Ledger</title><description>#{description}</description>#{owner}#{tag}
          <item><title>Ep 1</title><pubDate>Mon, 12 Oct 2026 09:00:00 -0000</pubDate><guid>f-1</guid></item>
        </channel>
      </rss>
    XML
  end

  def stub_claim_feed(url, **feed)
    allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ])
    stub_request(:get, url).to_return(status: 200, body: claim_feed_xml(**feed))
  end
end

RSpec.configure do |config|
  config.include ClaimFeeds
end
