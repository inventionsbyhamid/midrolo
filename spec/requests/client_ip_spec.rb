require "rails_helper"

# Who the client is in production (config/initializers/client_ip.rb): request.remote_ip, which the per-IP rate limits
# and Devise's sign-in tracking read. Traefik (on the Docker network) and Thruster (in the web container) sit in front
# of Puma, both on private addresses Rails trusts, and each appends the address it heard from to X-Forwarded-For.
# With Cloudflare's proxy on, a Cloudflare edge server comes before Traefik.
RSpec.describe "The client's IP" do
  let(:thruster) { { "REMOTE_ADDR" => "127.0.0.1" } }
  let(:traefik) { "172.18.0.5" }
  let(:edge) { "173.245.48.10" } # in Cloudflare's published ranges
  let(:client) { "198.51.100.1" }

  def remote_ip_after(headers)
    get "/pricing", headers: headers, env: thruster
    expect(response).to have_http_status(:ok)
    request.remote_ip
  end

  it "is the address Traefik heard from, read from X-Forwarded-For" do
    expect(remote_ip_after("X-Forwarded-For" => "#{client}, #{traefik}")).to eq(client)
  end

  it "ignores a Forwarded header the client sent" do
    headers = { "X-Forwarded-For" => "#{client}, #{traefik}", "Forwarded" => "for=203.0.113.7" }
    expect(remote_ip_after(headers)).to eq(client)
  end

  it "ignores a Client-IP header that names the same client" do
    expect(remote_ip_after("X-Forwarded-For" => "#{client}, #{traefik}", "Client-IP" => client)).to eq(client)
  end

  describe "a Client-IP header that names someone else" do
    let(:headers) { { "X-Forwarded-For" => "#{client}, #{traefik}", "Client-IP" => "203.0.113.7" } }

    it "gets the 400 page, not a 500, and no error report" do
      reports = []
      subscriber = Object.new.tap { |s| s.define_singleton_method(:report) { |error, **| reports << error } }
      Rails.error.subscribe(subscriber)

      %w[/pricing /up].each do |path|
        get path, headers: headers, env: thruster
        expect(response).to have_http_status(:bad_request)
        expect(response.media_type).to eq("text/html")
        expect(Nokogiri::HTML(response.body).at_css("h1").text).to eq("We couldn't read that request")
      end
      expect(reports).to be_empty
    ensure
      Rails.error.unsubscribe(subscriber)
    end

    it "is mapped to 400 wherever it is raised" do
      expect(ActionDispatch::ExceptionWrapper.status_code_for_exception("ActionDispatch::RemoteIp::IpSpoofAttackError"))
        .to eq(400)
    end
  end

  context "with Cloudflare's proxy on" do
    before do
      ranges = CloudflareRails::FallbackIps::IPS_V4 + CloudflareRails::FallbackIps::IPS_V6
      allow(CloudflareRails::Importer).to receive(:cloudflare_ips).and_return(ranges)
    end

    # Traefik's default: it drops the X-Forwarded-For of a peer it doesn't trust and writes only the edge it heard from.
    it "takes CF-Connecting-IP when Traefik heard from a Cloudflare edge and wrote only that" do
      headers = { "X-Forwarded-For" => "#{edge}, #{traefik}", "CF-Connecting-IP" => client }
      expect(remote_ip_after(headers)).to eq(client)
    end

    it "takes the client, not an address it made up, when Traefik passes Cloudflare's X-Forwarded-For along" do
      headers = { "X-Forwarded-For" => "203.0.113.66, #{client}, #{edge}, #{traefik}", "CF-Connecting-IP" => client }
      expect(remote_ip_after(headers)).to eq(client)
    end

    it "never takes CF-Connecting-IP from a client that skipped Cloudflare" do
      headers = { "X-Forwarded-For" => "#{client}, #{traefik}", "CF-Connecting-IP" => "203.0.113.7" }
      expect(remote_ip_after(headers)).to eq(client)

      headers = { "X-Forwarded-For" => "#{edge}, #{client}, #{traefik}", "CF-Connecting-IP" => "203.0.113.7" }
      expect(remote_ip_after(headers)).to eq(client)
    end

    it "keeps the edge when CF-Connecting-IP is missing or isn't an address" do
      expect(remote_ip_after("X-Forwarded-For" => "#{edge}, #{traefik}")).to eq(edge)
      expect(remote_ip_after("X-Forwarded-For" => "#{edge}, #{traefik}", "CF-Connecting-IP" => "nobody")).to eq(edge)
    end
  end
end
