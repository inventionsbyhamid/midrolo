require "rails_helper"

RSpec.describe Catalog::FeedFetcher do
  let(:url) { "https://feeds.example.com/tidepool.xml" }
  let(:xml) { Rails.root.join("spec/fixtures/feeds/catalog_namespace.xml").binread }

  before { allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ]) }

  it "returns the body, its digest and the validators" do
    stub_request(:get, url).to_return(status: 200, body: xml, headers: { "ETag" => %("v1"), "Last-Modified" => "Tue, 20 Oct 2026 09:00:00 GMT" })
    result = described_class.call(url)

    expect(result).to be_ok
    expect(result.body).to eq(xml)
    expect(result.sha256).to eq(Digest::SHA256.hexdigest(xml))
    expect([ result.etag, result.last_modified, result.truncated, result.moved_to ]).to eq([ %("v1"), "Tue, 20 Oct 2026 09:00:00 GMT", false, nil ])
  end

  it "asks conditionally and reports a 304 as not modified, keeping the validators" do
    stub_request(:get, url).with(headers: { "If-None-Match" => %("v1"), "If-Modified-Since" => "Tue, 20 Oct 2026 09:00:00 GMT" })
                           .to_return(status: 304)
    result = described_class.call(url, etag: %("v1"), last_modified: "Tue, 20 Oct 2026 09:00:00 GMT")

    expect(result).to be_not_modified
    expect([ result.body, result.etag ]).to eq([ nil, %("v1") ])
  end

  it "inflates a gzipped body" do
    stub_request(:get, url).to_return(status: 200, body: ActiveSupport::Gzip.compress(xml), headers: { "Content-Encoding" => "gzip" })
    expect(described_class.call(url).body).to eq(xml)
  end

  it "cuts a feed over the cap after its last whole episode, and refuses one without a whole episode" do
    stub_const("#{described_class}::MAX_BYTES", 2_500)
    stub_request(:get, url).to_return(status: 200, body: xml)
    result = described_class.call(url)

    expect(result).to be_ok
    expect(result.truncated).to be(true)
    expect(result.body).to end_with("</item></channel></rss>")
    expect(Catalog::FeedParser.call(result.body).episodes.map(&:guid)).to eq([ "tide-1" ])

    stub_const("#{described_class}::MAX_BYTES", 100)
    expect(described_class.call(url).error).to eq("feed_too_large")
  end

  it "follows redirects, reporting where a chain of permanent ones ends" do
    stub_request(:get, url).to_return(status: 301, headers: { "Location" => "https://new.example.com/feed" })
    stub_request(:get, "https://new.example.com/feed").to_return(status: 308, headers: { "Location" => "/final.xml" })
    stub_request(:get, "https://new.example.com/final.xml").to_return(status: 200, body: xml)

    result = described_class.call(url)
    expect(result).to be_ok
    expect(result.moved_to).to eq("https://new.example.com/final.xml")
  end

  it "doesn't report a move through a temporary redirect" do
    stub_request(:get, url).to_return(status: 302, headers: { "Location" => "https://cdn.example.com/feed" })
    stub_request(:get, "https://cdn.example.com/feed").to_return(status: 200, body: xml)
    expect(described_class.call(url).moved_to).to be_nil
  end

  it "stops a redirect loop and a chain that goes on too long" do
    stub_request(:get, url).to_return(status: 302, headers: { "Location" => "https://loop.example.com/b" })
    stub_request(:get, "https://loop.example.com/b").to_return(status: 302, headers: { "Location" => url })
    expect(described_class.call(url).error).to eq("feed_redirect_loop")

    7.times { |i| stub_request(:get, "https://hop.example.com/#{i}").to_return(status: 302, headers: { "Location" => "https://hop.example.com/#{i + 1}" }) }
    expect(described_class.call("https://hop.example.com/0").error).to eq("feed_too_many_redirects")
  end

  it "vets every hop: a redirect to an internal address is blocked before it is fetched" do
    allow(Resolv).to receive(:getaddresses).with("internal.example.com").and_return([ "10.0.0.5" ])
    stub_request(:get, url).to_return(status: 302, headers: { "Location" => "http://internal.example.com/feed" })

    expect(described_class.call(url).error).to eq("feed_blocked")
    expect(a_request(:get, "http://internal.example.com/feed")).not_to have_been_made
    expect(described_class.call("ftp://feeds.example.com/x").error).to eq("feed_blocked")
  end

  it "turns HTTP failures, timeouts and refused connections into error codes, never exceptions" do
    { 404 => "feed_not_found", 410 => "feed_gone", 403 => "feed_forbidden", 429 => "feed_rate_limited",
      503 => "feed_server_error", 418 => "feed_http_418" }.each do |status, code|
      stub_request(:get, url).to_return(status: status)
      expect(described_class.call(url).error).to eq(code)
    end

    stub_request(:get, url).to_timeout
    expect(described_class.call(url).error).to eq("feed_timeout")
    stub_request(:get, url).to_raise(Errno::ECONNREFUSED)
    expect(described_class.call(url).error).to eq("feed_unreachable")
    stub_request(:get, url).to_return(status: 200, body: "   ")
    expect(described_class.call(url).error).to eq("feed_empty")
  end

  it "gives up at the deadline" do
    stub_const("#{described_class}::TOTAL_TIMEOUT", 0.3)
    stub_request(:get, url).to_return { sleep 1; { status: 200, body: xml } }
    expect(described_class.call(url).error).to eq("feed_timeout")
  end

  it "makes up the demo directory's feeds without the network" do
    result = described_class.call("fake://fake-1")
    expect(result).to be_ok
    expect(Catalog::FeedParser.call(result.body).title).to eq("The Founder's Ledger")
    expect(described_class.call("fake://fake-999").error).to eq("feed_not_found")
  end
end
