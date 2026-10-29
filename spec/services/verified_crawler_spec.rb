require "rails_helper"

RSpec.describe VerifiedCrawler do
  let(:googlebot_agent) { "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" }
  let(:bingbot_agent) { "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)" }
  let(:browser_agent) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36" }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:dns) { instance_double(Resolv::DNS, "timeouts=": nil) }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
    allow(Resolv::DNS).to receive(:open) { |&block| block.call(dns) }
  end

  # names: ip => PTR name (none raises, as Resolv does); addresses: host => its A records.
  def dns_answers(names: {}, addresses: {})
    allow(dns).to receive(:getname) { |ip| names.fetch(ip) { raise Resolv::ResolvError, "no name for #{ip}" } }
    allow(dns).to receive(:getaddresses) { |name| addresses.fetch(name, []).map { |address| Resolv::IPv4.create(address) } }
  end

  def request(ip, agent, method: "GET")
    ActionDispatch::Request.new(Rack::MockRequest.env_for("/podcasts", "REMOTE_ADDR" => ip, "HTTP_USER_AGENT" => agent, method: method))
  end

  it "verifies a crawler whose reverse name is the search engine's and resolves back to the same IP, and caches it" do
    dns_answers(names: { "66.249.66.1" => "crawl-66-249-66-1.googlebot.com." },
                addresses: { "crawl-66-249-66-1.googlebot.com" => [ "66.249.66.1" ] })

    expect(described_class.verified?(request("66.249.66.1", googlebot_agent))).to be(true)
    expect(described_class.verified?(request("66.249.66.1", googlebot_agent, method: "HEAD"))).to be(true)
    expect(dns).to have_received(:getname).once
  end

  it "verifies Bing's crawler on search.msn.com" do
    dns_answers(names: { "157.55.39.1" => "msnbot-157-55-39-1.search.msn.com" },
                addresses: { "msnbot-157-55-39-1.search.msn.com" => [ "157.55.39.1" ] })
    expect(described_class.verified?(request("157.55.39.1", bingbot_agent))).to be(true)
  end

  it "never trusts the user agent alone: no reverse name, a look-alike domain, or a name that doesn't resolve back" do
    dns_answers(names: { "203.0.113.2" => "crawl.googlebot.com.example.net", "203.0.113.3" => "crawl-1.googlebot.com",
                         "203.0.113.4" => "evilgooglebot.com" },
                addresses: { "crawl-1.googlebot.com" => [ "66.249.66.9" ] })

    %w[203.0.113.1 203.0.113.2 203.0.113.3 203.0.113.4].each do |ip|
      expect(described_class.verified?(request(ip, googlebot_agent))).to be(false), ip
    end
  end

  it "never accepts googleusercontent.com, where anyone's cloud machine resolves" do
    dns_answers(names: { "34.1.2.3" => "3.2.1.34.bc.googleusercontent.com" },
                addresses: { "3.2.1.34.bc.googleusercontent.com" => [ "34.1.2.3" ] })
    expect(described_class.verified?(request("34.1.2.3", googlebot_agent))).to be(false)
  end

  it "wants the domain of the crawler the user agent names" do
    dns_answers(names: { "66.249.66.1" => "crawl-66-249-66-1.googlebot.com" },
                addresses: { "crawl-66-249-66-1.googlebot.com" => [ "66.249.66.1" ] })
    expect(described_class.verified?(request("66.249.66.1", bingbot_agent))).to be(false)
  end

  it "looks nothing up for a browser, for a write, or twice for an IP that failed" do
    dns_answers
    expect(described_class.verified?(request("66.249.66.1", browser_agent))).to be(false)
    expect(described_class.verified?(request("66.249.66.1", googlebot_agent, method: "POST"))).to be(false)
    expect(Resolv::DNS).not_to have_received(:open)

    2.times { expect(described_class.verified?(request("203.0.113.1", googlebot_agent))).to be(false) }
    expect(dns).to have_received(:getname).once
  end

  it "says no when DNS fails" do
    allow(dns).to receive(:getname).and_raise(Errno::ECONNREFUSED)
    expect(described_class.verified?(request("66.249.66.1", googlebot_agent))).to be(false)
  end
end
